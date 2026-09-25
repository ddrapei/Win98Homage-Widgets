//! The note file's bytes, and the edit box's UTF-16, and the trip between them.
//!
//! A note is UTF-8.  An edit changes what was typed and nothing else: a file
//! that came in with CRLF goes out with CRLF, and one with a BOM keeps it.
//!
//! The one thing an edit does change on purpose is a note from before the
//! skin was UTF-8, when it was written in the Windows-1252 code page.  Such a
//! file is not valid UTF-8, so it is read as 1252 and written back as UTF-8 --
//! once, the first time it is edited, and without losing a character, because
//! every 1252 character has a UTF-8 spelling.  Skin.lua reads such a file the
//! same way until then (its CP1252 table matches the one here), so the note
//! looks the same before and after.

const BOM: &[u8] = b"\xEF\xBB\xBF";
const CR: u16 = b'\r' as u16;
const LF: u16 = b'\n' as u16;

/// How a file was written, so it can be written back the same way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Format {
    pub bom: bool,
    pub crlf: bool,
}

/// File bytes to what an edit control wants: UTF-16 with every line break,
/// whatever it was, as CR LF -- a multi-line edit shows a bare LF as a glyph.
pub fn decode(bytes: &[u8]) -> (Vec<u16>, Format) {
    let (bom, body) = match bytes.strip_prefix(BOM) {
        Some(rest) => (true, rest),
        None => (false, bytes),
    };
    let crlf = bytes.windows(2).any(|w| w == b"\r\n");
    let wide: Vec<u16> = match core::str::from_utf8(body) {
        Ok(s) => s.encode_utf16().collect(),
        Err(_) => body.iter().map(|&b| from_1252(b)).collect(),
    };
    (to_crlf(&wide), Format { bom, crlf })
}

/// Edit control text back to file bytes: UTF-8, in the file's own line
/// endings, ending in one line break when there is anything in it -- the way
/// Skin.lua writes.
pub fn encode(text: &[u16], format: Format) -> Vec<u8> {
    let mut wide: Vec<u16> = if format.crlf {
        text.to_vec()
    } else {
        let mut out = Vec::with_capacity(text.len());
        let mut i = 0;
        while i < text.len() {
            if text[i] == CR && text.get(i + 1) == Some(&LF) {
                i += 1; // drop the CR, keep the LF
            }
            out.push(text[i]);
            i += 1;
        }
        out
    };
    if wide.last().is_some_and(|&c| c != LF) {
        if format.crlf {
            wide.push(CR);
        }
        wide.push(LF);
    }

    let mut out = if format.bom { BOM.to_vec() } else { Vec::new() };
    out.extend_from_slice(String::from_utf16_lossy(&wide).as_bytes());
    out
}

fn to_crlf(text: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(text.len() + text.len() / 16);
    let mut i = 0;
    while i < text.len() {
        match text[i] {
            CR => {
                out.extend_from_slice(&[CR, LF]);
                if text.get(i + 1) == Some(&LF) {
                    i += 1;
                }
            }
            LF => out.extend_from_slice(&[CR, LF]),
            c => out.push(c),
        }
        i += 1;
    }
    out
}

/// Windows-1252: Latin-1, except for 0x80..0x9F.  The five bytes 1252 leaves
/// undefined map to the same code point, as Windows itself maps them.
fn from_1252(b: u8) -> u16 {
    const HIGH: [u16; 32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ];
    match b {
        0x80..=0x9F => HIGH[usize::from(b - 0x80)],
        _ => u16::from(b),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn lf_file_round_trips() {
        let file = b"[ ] milk\n[x] eggs\n";
        let (text, format) = decode(file);
        assert_eq!(text, w("[ ] milk\r\n[x] eggs\r\n"));
        assert_eq!(format, Format { bom: false, crlf: false });
        assert_eq!(encode(&text, format), file);
    }

    #[test]
    fn crlf_and_bom_are_kept() {
        let file = b"\xEF\xBB\xBFone\r\ntwo\r\n";
        let (text, format) = decode(file);
        assert_eq!(text, w("one\r\ntwo\r\n"));
        assert_eq!(format, Format { bom: true, crlf: true });
        assert_eq!(encode(&text, format), file);
    }

    #[test]
    fn a_final_line_break_is_added_once() {
        let format = Format::default();
        assert_eq!(encode(&w("a\r\nb"), format), b"a\nb\n");
        assert_eq!(encode(&w("a\r\nb\r\n"), format), b"a\nb\n");
        assert_eq!(encode(&w(""), format), b"");
        let crlf = Format { crlf: true, ..format };
        assert_eq!(encode(&w("a"), crlf), b"a\r\n");
    }

    #[test]
    fn utf8_round_trips() {
        let file = "привіт, café 🍵\n".as_bytes();
        let (text, format) = decode(file);
        assert_eq!(text, w("привіт, café 🍵\r\n"));
        assert_eq!(encode(&text, format), file);
    }

    #[test]
    fn a_1252_note_is_read_as_1252_and_written_as_utf8() {
        // é, the euro sign and an en dash: Latin-1 and the 0x80 block both
        let (text, format) = decode(b"caf\xE9 \x80\x96\n");
        assert_eq!(text, w("café €–\r\n"));
        assert_eq!(encode(&text, format), "café €–\n".as_bytes());
    }

    #[test]
    fn stray_carriage_returns_become_line_breaks() {
        assert_eq!(decode(b"a\rb\n").0, w("a\r\nb\r\n"));
    }
}
