//! The Rainmeter plugin API, as Rainmeter.dll exports it.  Nothing outside the
//! rainmeter module uses these.
//!
//! Exported by Rainmeter.dll, which is already loaded in the process that loads
//! this one.  There is no import library on this machine, hence raw-dylib: the
//! linker builds the import table from these declarations alone.

#![allow(non_snake_case)]

use core::ffi::c_void;

type BOOL = i32;

pub const RMG_SKIN: i32 = 1;
pub const RMG_SKINWINDOWHANDLE: i32 = 4;
pub const LOG_ERROR: i32 = 1;

#[cfg(not(test))]
#[link(name = "Rainmeter", kind = "raw-dylib")]
unsafe extern "system" {
    pub fn RmReadString(rm: *mut c_void, option: *const u16, default: *const u16, replace_measures: BOOL) -> *const u16;
    pub fn RmReadFormula(rm: *mut c_void, option: *const u16, default: f64) -> f64;
    pub fn RmPathToAbsolute(rm: *mut c_void, path: *const u16) -> *const u16;
    pub fn RmExecute(skin: *mut c_void, command: *const u16);
    pub fn RmGet(rm: *mut c_void, kind: i32) -> *mut c_void;
    pub fn RmLog(rm: *mut c_void, level: i32, message: *const u16);
}

// The unit tests run as an ordinary executable, where there is no Rainmeter.dll
// to bind to.  They never reach these; they only have to link.
#[cfg(test)]
mod rainmeter_stubs {
    use super::{BOOL, c_void};
    pub unsafe fn RmReadString(_: *mut c_void, _: *const u16, d: *const u16, _: BOOL) -> *const u16 { d }
    pub unsafe fn RmReadFormula(_: *mut c_void, _: *const u16, d: f64) -> f64 { d }
    pub unsafe fn RmPathToAbsolute(_: *mut c_void, p: *const u16) -> *const u16 { p }
    pub unsafe fn RmExecute(_: *mut c_void, _: *const u16) {}
    pub unsafe fn RmGet(_: *mut c_void, _: i32) -> *mut c_void { core::ptr::null_mut() }
    pub unsafe fn RmLog(_: *mut c_void, _: i32, _: *const u16) {}
}
#[cfg(test)]
pub use rainmeter_stubs::*;
