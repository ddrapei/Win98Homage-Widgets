//! The box: a borderless popup with the edit control filling it, and the
//! session's [`Editor`].
//!
//! It is a top-level window owned by the skin's window, not a child of it: a
//! skin is a layered window drawn with UpdateLayeredWindow, and such a window
//! does not paint its children.  Owned is the next best thing -- it stays above
//! the skin, never gets a taskbar button, and when it stops being the active
//! window, which is exactly what a click outside it means, Windows says so with
//! WM_ACTIVATE.  That one message is the whole of "click outside to finish".
//!
//! What the popup handles itself is presentation -- colours, focus, the
//! autosave timer.  What it means for the note, it hands to the session as an
//! [`EditorEvents`] call: the user left, typing paused, the box is going away.

use core::cell::{Cell, RefCell};
use core::ffi::c_void;
use core::ptr::{null, null_mut};

use super::class::{Lease, WindowClass, this_module};
use super::edit::{EditControl, WM_LEAVE};
use super::gdi::{Brush, Font, colorref};
use super::sys::*;
use crate::command::View;
use crate::session::{Editor, EditorEvents};
use crate::settings::Settings;
use crate::wide::to_wide;

static CLASS: WindowClass = WindowClass::new("Win98NoteEdit", host_proc);
const AUTOSAVE_TIMER: usize = 1;

pub struct Popup {
    owner: HWND,
    host: Cell<HWND>,
    edit: Cell<Option<EditControl>>,
    font: RefCell<Option<Font>>,
    brush: RefCell<Option<Brush>>,
    ink: Cell<COLORREF>,
    paper: Cell<COLORREF>,
    autosave_ms: Cell<u32>,
    events: Cell<Option<*const dyn EditorEvents>>,
    /// Keeps the window class registered while this popup may have a window.
    lease: RefCell<Option<Lease>>,
}

impl Popup {
    /// A popup for the skin whose window is `owner`.  No window is made until
    /// the session first asks for one.
    pub fn new(owner: *mut c_void) -> Popup {
        Popup {
            owner,
            host: Cell::new(null_mut()),
            edit: Cell::new(None),
            font: RefCell::new(None),
            brush: RefCell::new(None),
            ink: Cell::new(0),
            paper: Cell::new(0x00FF_FFFF),
            autosave_ms: Cell::new(0),
            events: Cell::new(None),
            lease: RefCell::new(None),
        }
    }

    /// Who hears about the box.  `events` must stay where it is for as long as
    /// this popup does -- the plugin keeps both in one heap allocation.
    pub fn listen(&self, events: &(dyn EditorEvents + 'static)) {
        self.events.set(Some(events as *const dyn EditorEvents));
    }

    fn events(&self) -> Option<&dyn EditorEvents> {
        // SAFETY: see listen(); cleared before the popup goes.
        self.events.get().map(|p| unsafe { &*p })
    }

    /// A message for the box, arriving through host_proc.
    fn handle(&self, wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        unsafe {
            match msg {
                // Losing activation is leaving.  Gaining it, the keyboard goes
                // to the text and not to the frame around it.
                WM_ACTIVATE => {
                    if (wp & 0xFFFF) == WA_INACTIVE {
                        PostMessageW(wnd, WM_LEAVE, 0, 0);
                    } else if let Some(edit) = self.edit.get() {
                        SetFocus(edit.hwnd());
                    }
                    0
                }
                WM_LEAVE => {
                    if let Some(events) = self.events() {
                        events.on_leave();
                    }
                    0
                }
                // Every keystroke restarts the timer, so it fires once typing
                // has stopped for the whole delay.
                WM_COMMAND if ((wp >> 16) & 0xFFFF) == EN_CHANGE => {
                    let ms = self.autosave_ms.get();
                    if ms > 0 {
                        SetTimer(wnd, AUTOSAVE_TIMER, ms, null());
                    }
                    0
                }
                WM_TIMER if wp == AUTOSAVE_TIMER => {
                    KillTimer(wnd, AUTOSAVE_TIMER);
                    if let Some(events) = self.events() {
                        events.on_pause();
                    }
                    0
                }
                WM_CTLCOLOREDIT => {
                    let dc = wp as HDC;
                    SetTextColor(dc, self.ink.get());
                    SetBkColor(dc, self.paper.get());
                    self.brush.borrow().as_ref().map_or(null_mut(), Brush::handle) as LRESULT
                }
                WM_ERASEBKGND => 1, // the edit control covers every pixel
                // However the box goes -- the skin unloading or refreshing, or
                // its window being destroyed and taking this one with it -- the
                // session hears first, while the edit control still holds the
                // text: children are destroyed after their parent hears.
                WM_DESTROY => {
                    KillTimer(wnd, AUTOSAVE_TIMER);
                    if let Some(events) = self.events() {
                        events.on_closing();
                    }
                    0
                }
                WM_NCDESTROY => {
                    SetWindowLongPtrW(wnd, GWLP_USERDATA, 0);
                    self.host.set(null_mut());
                    self.edit.set(None);
                    DefWindowProcW(wnd, msg, wp, lp)
                }
                _ => DefWindowProcW(wnd, msg, wp, lp),
            }
        }
    }
}

impl Editor for Popup {
    fn create(&self) -> bool {
        if !self.host.get().is_null() {
            return true;
        }
        let lease = CLASS.lease();
        let module = this_module();
        let host = unsafe {
            CreateWindowExW(
                WS_EX_TOOLWINDOW, lease.name().as_ptr(), to_wide("").as_ptr(),
                WS_POPUP | WS_CLIPCHILDREN, 0, 0, 0, 0, self.owner, null_mut(), module,
                self as *const Popup as *mut c_void,
            )
        };
        if host.is_null() {
            return false; // and the lease goes, unregistering the class
        }
        self.host.set(host);
        let Some(edit) = EditControl::create(host, module) else {
            unsafe { DestroyWindow(host) };
            return false;
        };
        self.edit.set(Some(edit));
        *self.lease.borrow_mut() = Some(lease);
        true
    }

    fn is_open(&self) -> bool {
        let host = self.host.get();
        !host.is_null() && unsafe { IsWindowVisible(host) } != 0
    }

    fn configure(&self, s: &Settings) {
        let Some(edit) = self.edit.get() else { return };
        // New objects in before the old ones go: the control never holds a
        // deleted font, and replace() holds its borrow only for the swap.
        if let Some(font) = Font::new(&s.look.font) {
            edit.set_font(&font);
            self.font.replace(Some(font));
        }
        if let Some(brush) = Brush::solid(s.look.paper) {
            self.brush.replace(Some(brush));
        }
        self.ink.set(colorref(s.look.ink));
        self.paper.set(colorref(s.look.paper));
        self.autosave_ms.set(s.autosave_ms);

        let f = s.frame;
        let mut skin = RECT::default();
        unsafe {
            GetWindowRect(self.owner, &mut skin);
            MoveWindow(self.host.get(), skin.left + f.x, skin.top + f.y, f.w, f.h, 0);
        }
        edit.fit(f.w, f.h, f.padding);
    }

    fn load(&self, text: &[u16]) {
        if let Some(edit) = self.edit.get() {
            edit.replace_text(text);
        }
    }

    fn text(&self) -> Vec<u16> {
        self.edit.get().map(EditControl::text).unwrap_or_default()
    }

    fn is_modified(&self) -> bool {
        self.edit.get().is_some_and(EditControl::is_modified)
    }

    fn mark_saved(&self) {
        if let Some(edit) = self.edit.get() {
            edit.set_modified(false);
        }
    }

    fn show(&self, view: Option<View>) {
        let Some(edit) = self.edit.get() else { return };
        if let Some(v) = view {
            edit.scroll_to(v.line, v.rows);
        }
        let host = self.host.get();
        unsafe {
            SetWindowPos(host, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOMOVE | SWP_NOSIZE);
            SetForegroundWindow(host);
            SetFocus(edit.hwnd());
        }
        if view.is_some() {
            edit.caret_to_pointer();
        }
    }

    fn hide(&self) {
        let host = self.host.get();
        unsafe {
            KillTimer(host, AUTOSAVE_TIMER);
            ShowWindow(host, SW_HIDE);
        }
    }

    fn request_leave(&self) {
        unsafe { PostMessageW(self.host.get(), WM_LEAVE, 0, 0) };
    }

    fn destroy(&self) {
        let host = self.host.get();
        if !host.is_null() {
            unsafe { DestroyWindow(host) }; // says on_closing on its way
        }
    }
}

impl Drop for Popup {
    /// The window goes before the lease does (fields drop after this), and
    /// nobody is told: whoever was listening may be gone already.
    fn drop(&mut self) {
        self.events.set(None);
        self.destroy();
    }
}

unsafe extern "system" fn host_proc(wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if msg == WM_NCCREATE {
            let create = lp as *const CREATESTRUCTW;
            SetWindowLongPtrW(wnd, GWLP_USERDATA, (*create).lpCreateParams as isize);
            return DefWindowProcW(wnd, msg, wp, lp);
        }
        match (GetWindowLongPtrW(wnd, GWLP_USERDATA) as *const Popup).as_ref() {
            Some(popup) => popup.handle(wnd, msg, wp, lp),
            None => DefWindowProcW(wnd, msg, wp, lp),
        }
    }
}
