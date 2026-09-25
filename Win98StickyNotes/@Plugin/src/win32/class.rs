//! A window class, registered while something holds a lease on it.
//!
//! Every skin using the plugin shares the one class.  It is registered with
//! the first lease and unregistered when the last is dropped, so it never
//! outlives the DLL whose window procedure it points at -- Rainmeter unloads a
//! plugin once no measure uses it, and a class left behind would point into
//! nothing.

use core::ptr::{null, null_mut};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::sys::*;
use crate::wide::to_wide;

pub struct WindowClass {
    name: &'static str,
    proc_: WNDPROC,
    leases: AtomicUsize,
}

impl WindowClass {
    pub const fn new(name: &'static str, proc_: WNDPROC) -> Self {
        WindowClass { name, proc_, leases: AtomicUsize::new(0) }
    }

    /// Registers the class if nobody holds it yet.  A failed registration is
    /// not reported here: CreateWindowExW will fail on it, and that is where
    /// the caller finds out.
    pub fn lease(&'static self) -> Lease {
        if self.leases.fetch_add(1, Ordering::Relaxed) == 0 {
            let name = to_wide(self.name);
            let wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                style: 0,
                lpfnWndProc: Some(self.proc_),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hInstance: this_module(),
                hIcon: null_mut(),
                hCursor: unsafe { LoadCursorW(null_mut(), IDC_IBEAM as *const u16) },
                hbrBackground: null_mut(),
                lpszMenuName: null(),
                lpszClassName: name.as_ptr(),
                hIconSm: null_mut(),
            };
            unsafe { RegisterClassExW(&wc) };
        }
        Lease { class: self }
    }
}

/// Holding one keeps the class registered.
pub struct Lease {
    class: &'static WindowClass,
}

impl Lease {
    pub fn name(&self) -> Vec<u16> {
        to_wide(self.class.name)
    }
}

impl Drop for Lease {
    /// Windows refuses to unregister a class that still has windows, so the
    /// holder destroys its window before letting go of the lease.
    fn drop(&mut self) {
        if self.class.leases.fetch_sub(1, Ordering::Relaxed) == 1 {
            unsafe { UnregisterClassW(self.name().as_ptr(), this_module()) };
        }
    }
}

/// This DLL, as a module handle: what classes and windows are registered to.
pub fn this_module() -> HINSTANCE {
    let mut module: HINSTANCE = null_mut();
    unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            this_module as *const u16,
            &mut module,
        );
    }
    module
}
