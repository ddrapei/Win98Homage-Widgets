//! The Win32 declarations the plugin uses, and nothing else.  Written out by
//! hand so the crate has no dependencies: every one of these is a stable,
//! documented ABI, and there are few enough of them to read.  Nothing outside
//! the win32 module uses them.

#![allow(non_snake_case, clippy::upper_case_acronyms)]

use core::ffi::c_void;

pub type HWND = *mut c_void;
pub type HFONT = *mut c_void;
pub type HBRUSH = *mut c_void;
pub type HDC = *mut c_void;
pub type HINSTANCE = *mut c_void;
pub type BOOL = i32;
pub type WPARAM = usize;
pub type LPARAM = isize;
pub type LRESULT = isize;
pub type COLORREF = u32;

pub type WNDPROC = unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT;
pub type SUBCLASSPROC =
    unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM, usize, usize) -> LRESULT;

#[repr(C)]
pub struct WNDCLASSEXW {
    pub cbSize: u32,
    pub style: u32,
    pub lpfnWndProc: Option<WNDPROC>,
    pub cbClsExtra: i32,
    pub cbWndExtra: i32,
    pub hInstance: HINSTANCE,
    pub hIcon: *mut c_void,
    pub hCursor: *mut c_void,
    pub hbrBackground: HBRUSH,
    pub lpszMenuName: *const u16,
    pub lpszClassName: *const u16,
    pub hIconSm: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct RECT {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct POINT {
    pub x: i32,
    pub y: i32,
}

/// Only the first field is read, and it is the first field of the real thing.
#[repr(C)]
pub struct CREATESTRUCTW {
    pub lpCreateParams: *mut c_void,
}

// ---- constants --------------------------------------------------------------

pub const WS_POPUP: u32 = 0x8000_0000;
pub const WS_CHILD: u32 = 0x4000_0000;
pub const WS_VISIBLE: u32 = 0x1000_0000;
pub const WS_CLIPCHILDREN: u32 = 0x0200_0000;
pub const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;

pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_AUTOVSCROLL: u32 = 0x0040;
pub const ES_WANTRETURN: u32 = 0x1000;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_ACTIVATE: u32 = 0x0006;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_SETFONT: u32 = 0x0030;
pub const WM_NCCREATE: u32 = 0x0081;
pub const WM_NCDESTROY: u32 = 0x0082;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_APP: u32 = 0x8000;
pub const WA_INACTIVE: usize = 0;

pub const EN_CHANGE: usize = 0x0300;

pub const EM_GETSEL: u32 = 0x00B0;
pub const EM_SETSEL: u32 = 0x00B1;
pub const EM_SETRECTNP: u32 = 0x00B4;
pub const EM_LINESCROLL: u32 = 0x00B6;
pub const EM_GETMODIFY: u32 = 0x00B8;
pub const EM_SETMODIFY: u32 = 0x00B9;
pub const EM_LINEINDEX: u32 = 0x00BB;
pub const EM_REPLACESEL: u32 = 0x00C2;
pub const EM_SETLIMITTEXT: u32 = 0x00C5;
pub const EM_LINEFROMCHAR: u32 = 0x00C9;
pub const EM_EMPTYUNDOBUFFER: u32 = 0x00CD;
pub const EM_GETFIRSTVISIBLELINE: u32 = 0x00CE;
pub const EM_SETMARGINS: u32 = 0x00D3;
pub const EM_CHARFROMPOS: u32 = 0x00D7;
pub const EC_LEFTMARGIN: usize = 0x0001;
pub const EC_RIGHTMARGIN: usize = 0x0002;

pub const VK_ESCAPE: usize = 0x1B;
pub const SW_HIDE: i32 = 0;
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_SHOWWINDOW: u32 = 0x0040;
pub const HWND_TOP: HWND = core::ptr::null_mut();
pub const GWLP_USERDATA: i32 = -21;
pub const IDC_IBEAM: usize = 32513;

pub const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x2;
pub const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

pub const FW_NORMAL: i32 = 400;
pub const FW_BOLD: i32 = 700;
pub const DEFAULT_CHARSET: u32 = 1;
pub const ANTIALIASED_QUALITY: u32 = 4;
pub const NONANTIALIASED_QUALITY: u32 = 3;

// ---- functions --------------------------------------------------------------

#[link(name = "user32")]
unsafe extern "system" {
    pub fn RegisterClassExW(wc: *const WNDCLASSEXW) -> u16;
    pub fn UnregisterClassW(name: *const u16, instance: HINSTANCE) -> BOOL;
    pub fn CreateWindowExW(
        ex_style: u32, class: *const u16, title: *const u16, style: u32,
        x: i32, y: i32, w: i32, h: i32,
        parent: HWND, menu: *mut c_void, instance: HINSTANCE, param: *mut c_void,
    ) -> HWND;
    pub fn DestroyWindow(wnd: HWND) -> BOOL;
    pub fn DefWindowProcW(wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT;
    pub fn SetWindowLongPtrW(wnd: HWND, index: i32, value: isize) -> isize;
    pub fn GetWindowLongPtrW(wnd: HWND, index: i32) -> isize;
    pub fn SetWindowPos(wnd: HWND, after: HWND, x: i32, y: i32, w: i32, h: i32, flags: u32) -> BOOL;
    pub fn MoveWindow(wnd: HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) -> BOOL;
    pub fn ShowWindow(wnd: HWND, cmd: i32) -> BOOL;
    pub fn IsWindowVisible(wnd: HWND) -> BOOL;
    pub fn SetForegroundWindow(wnd: HWND) -> BOOL;
    pub fn SetFocus(wnd: HWND) -> HWND;
    pub fn GetWindowRect(wnd: HWND, rect: *mut RECT) -> BOOL;
    pub fn GetClientRect(wnd: HWND, rect: *mut RECT) -> BOOL;
    pub fn GetCursorPos(point: *mut POINT) -> BOOL;
    pub fn ScreenToClient(wnd: HWND, point: *mut POINT) -> BOOL;
    pub fn SendMessageW(wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT;
    pub fn PostMessageW(wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> BOOL;
    pub fn SetTimer(wnd: HWND, id: usize, ms: u32, proc_: *const c_void) -> usize;
    pub fn KillTimer(wnd: HWND, id: usize) -> BOOL;
    pub fn GetWindowTextLengthW(wnd: HWND) -> i32;
    pub fn GetWindowTextW(wnd: HWND, buf: *mut u16, len: i32) -> i32;
    pub fn SetWindowTextW(wnd: HWND, text: *const u16) -> BOOL;
    pub fn LoadCursorW(instance: HINSTANCE, name: *const u16) -> *mut c_void;
}

#[link(name = "gdi32")]
unsafe extern "system" {
    pub fn CreateFontW(
        height: i32, width: i32, escapement: i32, orientation: i32, weight: i32,
        italic: u32, underline: u32, strike: u32, charset: u32, out_precision: u32,
        clip_precision: u32, quality: u32, pitch_and_family: u32, face: *const u16,
    ) -> HFONT;
    pub fn CreateSolidBrush(colour: COLORREF) -> HBRUSH;
    pub fn DeleteObject(object: *mut c_void) -> BOOL;
    pub fn SetTextColor(dc: HDC, colour: COLORREF) -> COLORREF;
    pub fn SetBkColor(dc: HDC, colour: COLORREF) -> COLORREF;
}

#[link(name = "comctl32")]
unsafe extern "system" {
    pub fn SetWindowSubclass(wnd: HWND, proc_: SUBCLASSPROC, id: usize, data: usize) -> BOOL;
    pub fn RemoveWindowSubclass(wnd: HWND, proc_: SUBCLASSPROC, id: usize) -> BOOL;
    pub fn DefSubclassProc(wnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    pub fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut HINSTANCE) -> BOOL;
}
