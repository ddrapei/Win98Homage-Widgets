//! The measure's options, read into plain values.
//!
//! Everything is read each time the box opens rather than once at load, so a
//! skin can change any of it with !SetOption or a variable -- the paper colour
//! follows #NoteBg# that way -- without a refresh.  Where the values come from
//! is behind [`Options`]: Rainmeter in the plugin, a table in the tests.

use std::path::PathBuf;

/// Something the options can be read from.
pub trait Options {
    /// A string option, with the skin's #variables# already resolved.
    fn string(&self, option: &str, default: &str) -> String;
    /// A string option holding bangs: its [section] references are left alone,
    /// for Rainmeter to resolve when the bangs run rather than now.
    fn action(&self, option: &str) -> String;
    /// A number option.  Formulas are allowed.
    fn number(&self, option: &str, default: f64) -> f64;
    /// A path, made absolute against the skin's folder.
    fn path(&self, relative: &str) -> PathBuf;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Colour {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Colour {
    pub const BLACK: Colour = Colour { r: 0, g: 0, b: 0 };
    pub const WHITE: Colour = Colour { r: 255, g: 255, b: 255 };

    /// "R,G,B[,A]" or "RRGGBB[AA]", Rainmeter's two ways of writing a colour.
    /// Alpha is dropped: an edit control has no use for it.
    pub fn parse(s: &str) -> Option<Colour> {
        let s = s.trim();
        let rgb: Vec<u8> = if s.contains(',') {
            s.split(',')
                .take(3)
                .map(|p| p.trim().parse::<f64>().ok().map(|v| v.clamp(0.0, 255.0).round() as u8))
                .collect::<Option<_>>()?
        } else if s.len() == 6 || s.len() == 8 {
            (0..3)
                .map(|i| u8::from_str_radix(s.get(2 * i..2 * i + 2)?, 16).ok())
                .collect::<Option<_>>()?
        } else {
            return None;
        };
        match rgb[..] {
            [r, g, b] => Some(Colour { r, g, b }),
            _ => None,
        }
    }
}

/// Space inside the box where the text may not go, in pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Padding {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Padding {
    /// "l,t,r,b", any of it missing counting as 0.
    pub fn parse(s: &str) -> Padding {
        let mut v = [0; 4];
        for (slot, part) in v.iter_mut().zip(s.split(',')) {
            *slot = part.trim().parse::<f64>().map_or(0, |n| n.round() as i32);
        }
        let [left, top, right, bottom] = v;
        Padding { left, top, right, bottom }
    }
}

/// Where the box sits, in pixels from the skin's top-left corner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Frame {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub padding: Padding,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FontSpec {
    pub face: String,
    /// Points, as Rainmeter's FontSize is.
    pub size: f64,
    pub bold: bool,
    pub italic: bool,
    pub antialias: bool,
}

/// How the box looks: paper, ink and type.
#[derive(Clone, Debug, PartialEq)]
pub struct Look {
    pub paper: Colour,
    pub ink: Colour,
    pub font: FontSpec,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub frame: Frame,
    pub look: Look,
    /// The note, absolute.
    pub file: PathBuf,
    /// Milliseconds of quiet before typing is written; 0 writes only on close.
    pub autosave_ms: u32,
    /// Bangs to run after every Open that does not leave the box open.
    pub on_close: String,
}

impl Settings {
    pub fn read(o: &impl Options) -> Settings {
        let pixels = |option: &str, default: f64| o.number(option, default).round() as i32;
        let style = o.string("StringStyle", "Normal").to_ascii_lowercase();

        Settings {
            frame: Frame {
                x: pixels("X", 0.0),
                y: pixels("Y", 0.0),
                w: pixels("W", 200.0).max(1),
                h: pixels("H", 100.0).max(1),
                padding: Padding::parse(&o.string("Padding", "0,0,0,0")),
            },
            look: Look {
                paper: Colour::parse(&o.string("SolidColor", "255,255,255")).unwrap_or(Colour::WHITE),
                ink: Colour::parse(&o.string("FontColor", "0,0,0")).unwrap_or(Colour::BLACK),
                font: FontSpec {
                    face: o.string("FontFace", "Microsoft Sans Serif"),
                    size: o.number("FontSize", 8.0).max(1.0),
                    bold: style.contains("bold"),
                    italic: style.contains("italic"),
                    antialias: o.number("AntiAlias", 0.0) != 0.0,
                },
            },
            file: o.path(&o.string("File", "Notes.txt")),
            autosave_ms: o.number("AutoSave", 1000.0).max(0.0) as u32,
            on_close: o.action("OnCloseAction"),
        }
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Options from a table, for tests: what a measure's section would hold.
    #[derive(Default)]
    pub struct Table(pub HashMap<&'static str, &'static str>);

    impl Table {
        pub fn with(pairs: &[(&'static str, &'static str)]) -> Table {
            Table(pairs.iter().copied().collect())
        }
    }

    impl Options for Table {
        fn string(&self, option: &str, default: &str) -> String {
            self.0.get(option).map_or(default, |v| v).to_owned()
        }
        fn action(&self, option: &str) -> String {
            self.string(option, "")
        }
        fn number(&self, option: &str, default: f64) -> f64 {
            self.0.get(option).and_then(|v| v.parse().ok()).unwrap_or(default)
        }
        fn path(&self, relative: &str) -> PathBuf {
            PathBuf::from(r"C:\Skin").join(relative)
        }
    }

    #[test]
    fn colours() {
        let c = |r, g, b| Some(Colour { r, g, b });
        assert_eq!(Colour::parse("250,238,190"), c(250, 238, 190));
        assert_eq!(Colour::parse(" 1, 2, 3, 255 "), c(1, 2, 3));
        assert_eq!(Colour::parse("300,-4,7.6"), c(255, 0, 8));
        assert_eq!(Colour::parse("FAEEBE"), c(250, 238, 190));
        assert_eq!(Colour::parse("FAEEBE80"), c(250, 238, 190));
        assert_eq!(Colour::parse("1,2"), None);
        assert_eq!(Colour::parse("#NoteBg#"), None);
    }

    #[test]
    fn paddings() {
        let p = |left, top, right, bottom| Padding { left, top, right, bottom };
        assert_eq!(Padding::parse("1,0,8,0"), p(1, 0, 8, 0));
        assert_eq!(Padding::parse("2"), p(2, 0, 0, 0));
        assert_eq!(Padding::parse(""), p(0, 0, 0, 0));
    }

    #[test]
    fn the_sticky_notes_own_options() {
        let s = Settings::read(&Table::with(&[
            ("X", "33"), ("Y", "42"), ("W", "149"), ("H", "156"), ("Padding", "1,0,8,0"),
            ("SolidColor", "250,238,190"), ("FontColor", "28,22,14"),
            ("FontFace", "Microsoft Sans Serif"), ("FontSize", "8"), ("AntiAlias", "0"),
            ("File", "Notes.txt"), ("AutoSave", "1000"),
            ("OnCloseAction", r#"[!CommandMeasure MeasureSkin "Closed()"]"#),
        ]));
        assert_eq!(s.frame, Frame { x: 33, y: 42, w: 149, h: 156, padding: Padding::parse("1,0,8,0") });
        assert_eq!(s.look.paper, Colour { r: 250, g: 238, b: 190 });
        assert_eq!(s.look.ink, Colour { r: 28, g: 22, b: 14 });
        assert!(!s.look.font.bold && !s.look.font.italic && !s.look.font.antialias);
        assert_eq!(s.file, PathBuf::from(r"C:\Skin\Notes.txt"));
        assert_eq!(s.autosave_ms, 1000);
        assert_eq!(s.on_close, r#"[!CommandMeasure MeasureSkin "Closed()"]"#);
    }

    #[test]
    fn defaults_and_limits() {
        let s = Settings::read(&Table::with(&[
            ("W", "0"), ("H", "-5"), ("AutoSave", "-1"), ("FontSize", "0"),
            ("StringStyle", "BoldItalic"), ("SolidColor", "nonsense"),
        ]));
        assert_eq!((s.frame.w, s.frame.h), (1, 1));
        assert_eq!(s.autosave_ms, 0);
        assert_eq!(s.look.font.size, 1.0);
        assert!(s.look.font.bold && s.look.font.italic);
        assert_eq!(s.look.paper, Colour::WHITE);
        assert_eq!(s.on_close, "");
    }
}
