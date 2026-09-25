//! The six functions Rainmeter calls, and the one object behind them.
//!
//! Each export is a line or two: find the measure, hand the call to its
//! session.  Everything the plugin does is decided in `session`; this file is
//! only the C ABI on the outside of it.

use core::cell::RefCell;
use core::ffi::c_void;
use core::ptr::null;

use crate::command::Command;
use crate::rainmeter::Rainmeter;
use crate::session::{Session, Skin, Status};
use crate::wide::{string_from_wide, to_wide};
use crate::win32::Popup;

/// One per measure: a session, and its status as a string Rainmeter can read.
struct Measure {
    session: Session<Popup, Rainmeter>,
    /// GetString's answer, kept here so the pointer outlives the call.
    status: RefCell<(Status, Vec<u16>)>,
}

impl Measure {
    /// # Safety
    /// `data` is null, or what Initialize put there and Finalize has not freed.
    unsafe fn from<'a>(data: *mut c_void) -> Option<&'a Measure> {
        unsafe { data.cast::<Measure>().as_ref() }
    }

    fn status_text(&self) -> *const u16 {
        let now = self.session.status();
        let mut cached = self.status.borrow_mut();
        if cached.0 != now || cached.1.is_empty() {
            *cached = (now, to_wide(now.as_str()));
        }
        cached.1.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Initialize(data: *mut *mut c_void, rm: *mut c_void) {
    unsafe {
        let skin = Rainmeter::new(rm);
        let popup = Popup::new(skin.window());
        let measure = Box::new(Measure {
            session: Session::new(popup, skin),
            status: RefCell::new((Status::Idle, Vec::new())),
        });
        // The session has its final address now, inside the box, so the popup
        // can be told where to send its events.
        measure.session.editor().listen(&measure.session);
        *data = Box::into_raw(measure).cast();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Reload(data: *mut c_void, rm: *mut c_void, _max: *mut f64) {
    // Options are read when the box opens, not here.
    if let Some(m) = unsafe { Measure::from(data) } {
        m.session.skin().rebind(rm);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Update(data: *mut c_void) -> f64 {
    let open = unsafe { Measure::from(data) }.is_some_and(|m| m.session.is_open());
    if open { 1.0 } else { 0.0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn GetString(data: *mut c_void) -> *const u16 {
    unsafe { Measure::from(data) }.map_or(null(), Measure::status_text)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ExecuteBang(data: *mut c_void, args: *const u16) {
    let Some(m) = (unsafe { Measure::from(data) }) else { return };
    match unsafe { string_from_wide(args) }.parse::<Command>() {
        Ok(command) => m.session.run(command),
        Err(e) => m.session.skin().log(&e),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn Finalize(data: *mut c_void) {
    if data.is_null() {
        return;
    }
    let measure = unsafe { Box::from_raw(data.cast::<Measure>()) };
    measure.session.shutdown(); // saves, while the session is still whole
}
