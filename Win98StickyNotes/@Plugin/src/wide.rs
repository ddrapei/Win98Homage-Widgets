//! UTF-16 strings, the way both C APIs this plugin talks to -- Win32 and
//! Rainmeter -- hand them over and want them back.

/// `s` as UTF-16 with a terminating NUL, ready to pass as an LPCWSTR.
pub fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// A NUL-terminated UTF-16 string that belongs to someone else, copied out
/// without its NUL.
///
/// # Safety
/// `p` is null, or points at a NUL-terminated UTF-16 string that stays put
/// for the length of the call.
pub unsafe fn copy_wide(p: *const u16) -> Vec<u16> {
    if p.is_null() {
        return Vec::new();
    }
    let mut n = 0;
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    unsafe { core::slice::from_raw_parts(p, n) }.to_vec()
}

/// The same, as a Rust string.  Unpaired surrogates become U+FFFD.
///
/// # Safety
/// As for [`copy_wide`].
pub unsafe fn string_from_wide(p: *const u16) -> String {
    String::from_utf16_lossy(&unsafe { copy_wide(p) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let w = to_wide("кава ☕");
        assert_eq!(w.last(), Some(&0));
        assert_eq!(unsafe { string_from_wide(w.as_ptr()) }, "кава ☕");
        assert!(unsafe { copy_wide(core::ptr::null()) }.is_empty());
    }
}
