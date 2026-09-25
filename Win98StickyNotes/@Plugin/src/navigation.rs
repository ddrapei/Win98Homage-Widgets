//! Finding your way around the edit box's text: where a line starts, and where
//! the word before the caret starts.  Pure functions over the box's UTF-16, in
//! which every line break is CR LF, so the edit control's wrappers can stay
//! thin and these can be tested on their own.

const CR: u16 = b'\r' as u16;
const LF: u16 = b'\n' as u16;

/// Where the 1-based `line` of `text` starts, in UTF-16 units: the argument
/// EM_LINEFROMCHAR wants.  Past the end is the end.
pub fn line_start(text: &[u16], line: usize) -> usize {
    if line <= 1 {
        return 0;
    }
    text.iter()
        .enumerate()
        .filter(|&(_, &c)| c == LF)
        .nth(line - 2)
        .map_or(text.len(), |(i, _)| i + 1)
}

/// The start of the word before `at`, for CTRL-Backspace: back over any
/// spaces, then back over the word -- but never across a line break.  At the
/// very start of a line the break itself is what goes, and nothing with it.
pub fn word_start(text: &[u16], at: usize) -> usize {
    let at = at.min(text.len());
    let blank = |c: u16| c == b' ' as u16 || c == b'\t' as u16;
    let mut i = at;
    while i > 0 && blank(text[i - 1]) {
        i -= 1;
    }
    if i == at && i > 0 && text[i - 1] == LF {
        return if i >= 2 && text[i - 2] == CR { i - 2 } else { i - 1 };
    }
    while i > 0 && !blank(text[i - 1]) && text[i - 1] != LF {
        i -= 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn line_starts() {
        let text = w("ab\r\ncd\r\nef");
        assert_eq!(line_start(&text, 0), 0);
        assert_eq!(line_start(&text, 1), 0);
        assert_eq!(line_start(&text, 2), 4);
        assert_eq!(line_start(&text, 3), 8);
        assert_eq!(line_start(&text, 9), text.len());
    }

    #[test]
    fn word_starts() {
        let text = w("buy oat milk  ");
        assert_eq!(word_start(&text, text.len()), 8);
        assert_eq!(word_start(&text, 7), 4);
        assert_eq!(word_start(&text, 3), 0);
        assert_eq!(word_start(&text, 0), 0);

        let text = w("ab\r\n  cd");
        assert_eq!(word_start(&text, 8), 6);    // the word
        assert_eq!(word_start(&text, 6), 4);    // then the indent
        assert_eq!(word_start(&text, 4), 2);    // then the line break alone
    }
}
