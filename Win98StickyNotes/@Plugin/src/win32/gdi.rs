//! The two GDI objects the box paints with, owned: each is deleted when it is
//! dropped, so replacing one is an assignment and nothing leaks.

use super::sys::*;
use crate::settings::{Colour, FontSpec};
use crate::wide::to_wide;

/// Win32 packs a colour as 0x00BBGGRR.
pub fn colorref(c: Colour) -> COLORREF {
    u32::from(c.r) | u32::from(c.g) << 8 | u32::from(c.b) << 16
}

pub struct Font(HFONT);

impl Font {
    pub fn new(spec: &FontSpec) -> Option<Font> {
        // Rainmeter does not scale skins with the display, so neither does
        // this: points become pixels at 96 dpi, as they do on the skin.
        let height = -(spec.size * 96.0 / 72.0).round() as i32;
        let weight = if spec.bold { FW_BOLD } else { FW_NORMAL };
        let quality = if spec.antialias { ANTIALIASED_QUALITY } else { NONANTIALIASED_QUALITY };
        let face = to_wide(&spec.face);
        let font = unsafe {
            CreateFontW(height, 0, 0, 0, weight, spec.italic as u32, 0, 0,
                        DEFAULT_CHARSET, 0, 0, quality, 0, face.as_ptr())
        };
        (!font.is_null()).then_some(Font(font))
    }

    pub fn handle(&self) -> HFONT {
        self.0
    }
}

impl Drop for Font {
    fn drop(&mut self) {
        unsafe { DeleteObject(self.0) };
    }
}

pub struct Brush(HBRUSH);

impl Brush {
    pub fn solid(colour: Colour) -> Option<Brush> {
        let brush = unsafe { CreateSolidBrush(colorref(colour)) };
        (!brush.is_null()).then_some(Brush(brush))
    }

    pub fn handle(&self) -> HBRUSH {
        self.0
    }
}

impl Drop for Brush {
    fn drop(&mut self) {
        unsafe { DeleteObject(self.0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colours_pack_blue_green_red() {
        assert_eq!(colorref(Colour { r: 250, g: 238, b: 190 }), 0x00BE_EEFA);
    }
}
