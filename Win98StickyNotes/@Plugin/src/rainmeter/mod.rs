//! Rainmeter's plugin API, wrapped.  The rest of the crate never sees an `rm`
//! pointer: it reads options through [`Options`], and runs bangs and writes the
//! log through [`Skin`] -- both implemented here for the real thing, and both
//! faked in the tests.

mod sys;

use core::cell::Cell;
use core::ffi::c_void;
use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;

use crate::session::Skin;
use crate::settings::Options;
use crate::wide::{copy_wide, string_from_wide, to_wide};

/// One measure's link to Rainmeter.
///
/// Every call below trusts the pointers Rainmeter handed over to be valid for
/// as long as the measure exists, which is Rainmeter's side of the plugin
/// contract; that is what makes them safe to expose as safe methods.
pub struct Rainmeter {
    rm: Cell<*mut c_void>,
    skin: *mut c_void,
    window: *mut c_void,
}

impl Rainmeter {
    /// # Safety
    /// `rm` is the pointer Rainmeter passed to the measure's Initialize.
    pub unsafe fn new(rm: *mut c_void) -> Rainmeter {
        unsafe {
            Rainmeter {
                rm: Cell::new(rm),
                skin: sys::RmGet(rm, sys::RMG_SKIN),
                window: sys::RmGet(rm, sys::RMG_SKINWINDOWHANDLE),
            }
        }
    }

    /// Reload hands the pointer over again.  It is the same measure.
    pub fn rebind(&self, rm: *mut c_void) {
        self.rm.set(rm);
    }

    /// The skin's window.
    pub fn window(&self) -> *mut c_void {
        self.window
    }

    fn read(&self, option: &str, default: &str, replace_sections: bool) -> String {
        let (o, d) = (to_wide(option), to_wide(default));
        unsafe {
            string_from_wide(sys::RmReadString(self.rm.get(), o.as_ptr(), d.as_ptr(),
                                               replace_sections as i32))
        }
    }
}

impl Options for Rainmeter {
    fn string(&self, option: &str, default: &str) -> String {
        self.read(option, default, true)
    }

    fn action(&self, option: &str) -> String {
        self.read(option, "", false)
    }

    fn number(&self, option: &str, default: f64) -> f64 {
        unsafe { sys::RmReadFormula(self.rm.get(), to_wide(option).as_ptr(), default) }
    }

    fn path(&self, relative: &str) -> PathBuf {
        let relative = to_wide(relative);
        let absolute = unsafe { copy_wide(sys::RmPathToAbsolute(self.rm.get(), relative.as_ptr())) };
        OsString::from_wide(&absolute).into()
    }
}

impl Skin for Rainmeter {
    fn run(&self, action: &str) {
        unsafe { sys::RmExecute(self.skin, to_wide(action).as_ptr()) };
    }

    fn log(&self, message: &str) {
        let message = to_wide(&format!("NoteEdit: {message}"));
        unsafe { sys::RmLog(self.rm.get(), sys::LOG_ERROR, message.as_ptr()) };
    }
}
