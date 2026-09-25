//! The commands a skin can send the measure with !CommandMeasure.
//!
//!   Open [line [rows]]   put the box up, showing the file's 1-based `line` at
//!                        the top and `rows` wrapped rows into it -- the view the
//!                        sheet had when it was clicked
//!   Close                finish, exactly as a click outside the box would

use std::str::FromStr;

/// Where the sheet was scrolled to when it was clicked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct View {
    pub line: usize,
    pub rows: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Open(View),
    Close,
}

impl FromStr for Command {
    type Err = String;

    /// Case-insensitive, like Rainmeter's own bangs.  Numbers that are missing
    /// or unreadable take their defaults: line 1, no rows down.
    fn from_str(args: &str) -> Result<Command, String> {
        let mut words = args.split_whitespace();
        let name = words.next().unwrap_or("");
        let mut number = |default| words.next().and_then(|w| w.parse().ok()).unwrap_or(default);

        if name.eq_ignore_ascii_case("open") {
            let line = number(1);
            let rows = number(0);
            Ok(Command::Open(View { line, rows }))
        } else if name.eq_ignore_ascii_case("close") {
            Ok(Command::Close)
        } else {
            Err(format!("unknown command \"{}\"", args.trim()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_and_its_view() {
        let open = |line, rows| Ok(Command::Open(View { line, rows }));
        assert_eq!("Open 12 1".parse(), open(12, 1));
        assert_eq!("open".parse(), open(1, 0));
        assert_eq!("OPEN 5".parse(), open(5, 0));
        assert_eq!("Open x -2".parse(), open(1, 0));
    }

    #[test]
    fn close_and_the_rest() {
        assert_eq!("Close".parse(), Ok(Command::Close));
        assert_eq!("  close  ".parse(), Ok(Command::Close));
        assert!("ExecuteBatch 1-2".parse::<Command>().is_err());
        assert!("".parse::<Command>().is_err());
    }
}
