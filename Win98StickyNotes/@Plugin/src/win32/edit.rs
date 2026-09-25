//! The Windows EDIT control the typing happens in, behind named methods: each
//! one is a message or two, and the names say what the messages are for.
//!
//! It also fixes the three keys a plain edit control gets wrong for a note --
//! Escape, CTRL-A and CTRL-Backspace -- by subclassing it.

use core::ptr::null_mut;

use super::gdi::Font;
use super::sys::*;
use crate::navigation;
use crate::settings::Padding;
use crate::wide::to_wide;

/// Posted to the box when the user asks to leave it: Escape here, a click
/// outside it in the popup.  Posted and not sent, so it is handled once the
/// message that caused it is done with.
pub const WM_LEAVE: u32 = WM_APP + 1;

const SUBCLASS_ID: usize = 1;

#[derive(Clone, Copy)]
pub struct EditControl(HWND);

impl EditControl {
    /// A multi-line edit control filling `parent`, with the note's keys.
    pub fn create(parent: HWND, module: HINSTANCE) -> Option<EditControl> {
        let empty = to_wide("");
        let wnd = unsafe {
            CreateWindowExW(
                0, to_wide("EDIT").as_ptr(), empty.as_ptr(),
                WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN,
                0, 0, 0, 0, parent, SUBCLASS_ID as *mut _, module, null_mut(),
            )
        };
        if wnd.is_null() {
            return None;
        }
        unsafe {
            SendMessageW(wnd, EM_SETLIMITTEXT, 0, 0); // as long as a note gets
            SetWindowSubclass(wnd, keys, SUBCLASS_ID, parent as usize);
        }
        Some(EditControl(wnd))
    }

    pub fn hwnd(self) -> HWND {
        self.0
    }

    fn send(self, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        unsafe { SendMessageW(self.0, msg, wp, lp) }
    }

    pub fn text(self) -> Vec<u16> {
        unsafe {
            let n = GetWindowTextLengthW(self.0).max(0);
            let mut buf = vec![0u16; n as usize + 1];
            let got = GetWindowTextW(self.0, buf.as_mut_ptr(), n + 1).max(0);
            buf.truncate(got as usize);
            buf
        }
    }

    /// New contents, unmodified, with nothing to undo back into.
    pub fn replace_text(self, text: &[u16]) {
        let mut z = text.to_vec();
        z.push(0);
        unsafe { SetWindowTextW(self.0, z.as_ptr()) };
        self.send(EM_EMPTYUNDOBUFFER, 0, 0);
        self.set_modified(false);
    }

    pub fn is_modified(self) -> bool {
        self.send(EM_GETMODIFY, 0, 0) != 0
    }

    pub fn set_modified(self, modified: bool) {
        self.send(EM_SETMODIFY, modified as WPARAM, 0);
    }

    /// The font must outlive its use here: the control does not own it.
    pub fn set_font(self, font: &Font) {
        self.send(WM_SETFONT, font.handle() as WPARAM, 0);
    }

    /// Fill a w x h client area, keeping the text out of `padding`.
    pub fn fit(self, w: i32, h: i32, padding: Padding) {
        unsafe { MoveWindow(self.0, 0, 0, w, h, 0) };
        // A resize resets the text rectangle, so this comes after it.
        self.send(EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
        let area = RECT {
            left: padding.left,
            top: padding.top,
            right: w - padding.right,
            bottom: h - padding.bottom,
        };
        self.send(EM_SETRECTNP, 0, &area as *const RECT as LPARAM);
    }

    /// Scroll so the text's 1-based `line` is at the top, `rows` wrapped rows
    /// into it.
    pub fn scroll_to(self, line: usize, rows: usize) {
        let at = navigation::line_start(&self.text(), line);
        let target = self.send(EM_LINEFROMCHAR, at, 0) + rows as isize;
        let first = self.send(EM_GETFIRSTVISIBLELINE, 0, 0);
        self.send(EM_LINESCROLL, 0, target - first);
    }

    /// The caret under the mouse pointer -- where the click that opened the box
    /// landed -- or at the end if the pointer is not over the control.
    pub fn caret_to_pointer(self) {
        let mut p = POINT::default();
        let mut r = RECT::default();
        unsafe {
            GetCursorPos(&mut p);
            ScreenToClient(self.0, &mut p);
            GetClientRect(self.0, &mut r);
        }
        let inside = p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom;
        let at = if inside {
            let point = ((p.y as u16 as u32) << 16 | p.x as u16 as u32) as LPARAM;
            let hit = self.send(EM_CHARFROMPOS, 0, point) as u32;
            // Both halves are 16 bits, so past 64K characters the index wraps;
            // the line's own start puts back what was lost.
            let (low, line) = (hit & 0xFFFF, hit >> 16);
            let start = self.send(EM_LINEINDEX, line as usize, 0) as u32;
            start + (low.wrapping_sub(start) & 0xFFFF)
        } else {
            unsafe { GetWindowTextLengthW(self.0) }.max(0) as u32
        };
        self.send(EM_SETSEL, at as usize, at as LPARAM);
    }

    pub fn select_all(self) {
        self.send(EM_SETSEL, 0, -1);
    }

    /// CTRL-Backspace: the selection if there is one, else the word before the
    /// caret.
    pub fn delete_word_before_caret(self) {
        let (mut start, mut end) = (0u32, 0u32);
        self.send(EM_GETSEL, &mut start as *mut u32 as WPARAM, &mut end as *mut u32 as LPARAM);
        if start == end {
            let from = navigation::word_start(&self.text(), start as usize);
            self.send(EM_SETSEL, from, start as LPARAM);
        }
        let nothing = [0u16];
        self.send(EM_REPLACESEL, 1, nothing.as_ptr() as LPARAM);
    }
}

/// The subclass.  `parent` is the box, handed over when it was installed.
unsafe extern "system" fn keys(
    wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM, _id: usize, parent: usize,
) -> LRESULT {
    let edit = EditControl(wnd);
    unsafe {
        match (msg, wp) {
            (WM_KEYDOWN, VK_ESCAPE) => {
                PostMessageW(parent as HWND, WM_LEAVE, 0, 0);
                return 0;
            }
            (WM_CHAR, 0x1B) => return 0, // Escape's character: no beep
            (WM_CHAR, 0x01) => {
                edit.select_all(); // CTRL-A
                return 0;
            }
            (WM_CHAR, 0x7F) => {
                edit.delete_word_before_caret(); // would otherwise type a box glyph
                return 0;
            }
            (WM_NCDESTROY, _) => {
                RemoveWindowSubclass(wnd, keys, SUBCLASS_ID);
            }
            _ => {}
        }
        DefSubclassProc(wnd, msg, wp, lp)
    }
}
