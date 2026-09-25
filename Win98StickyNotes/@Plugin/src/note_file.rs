//! The note on disk: reading it, writing it back so that it is never half
//! written, and keeping the version from before an edit in the .bak beside it.
//!
//! Nothing here knows about windows, which is the point: this is the part that
//! can lose a note, so it is the part the tests drive directly.

use std::io;
use std::path::{Path, PathBuf};

use crate::codec::{self, Format};

pub struct NoteFile {
    path: PathBuf,
    format: Format,
    /// The file's bytes as of the last read or write; None if there was none.
    disk: Option<Vec<u8>>,
    /// Whether this edit has already put the previous note in the .bak file.
    backed_up: bool,
}

impl NoteFile {
    /// Read the note, for an edit to start from.  A missing file is an empty
    /// note; a file that is there but cannot be read is an error, because
    /// saving over it would destroy it.
    pub fn open(path: &Path) -> io::Result<(NoteFile, Vec<u16>)> {
        let disk = read_optional(path)?;
        let (text, format) = disk.as_deref().map(codec::decode).unwrap_or_default();
        let note = NoteFile { path: path.to_owned(), format, disk, backed_up: false };
        Ok((note, text))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Catch up with the file, for typing that is being kept because it could
    /// not be saved.  If something else wrote the note meanwhile -- a checkbox,
    /// another editor -- the typing still wins, since it is what is on screen,
    /// but the other version is not lost: it becomes what the next save backs
    /// up.  True if the file had changed.
    pub fn resync(&mut self) -> io::Result<bool> {
        let now = read_optional(&self.path)?;
        if now == self.disk {
            return Ok(false);
        }
        self.disk = now;
        self.backed_up = false;
        Ok(true)
    }

    /// Write `text` out if it is not what the file already holds.  Ok(true) is
    /// a write, Ok(false) is nothing to write.  On an error the note is as it
    /// was, and the same call can simply be made again.
    pub fn save(&mut self, text: &[u16]) -> io::Result<bool> {
        let bytes = codec::encode(text, self.format);
        let unchanged = match self.disk.as_deref() {
            Some(disk) => disk == bytes.as_slice(),
            None => bytes.is_empty(),
        };
        if unchanged {
            return Ok(false);
        }
        // The note as it was before this edit: once per edit rather than once
        // per autosave, or the backup would only ever be a second old.
        if !self.backed_up {
            if let Some(disk) = self.disk.as_deref() {
                std::fs::write(with_suffix(&self.path, ".bak"), disk)?;
            }
            self.backed_up = true;
        }
        write_whole(&self.path, &bytes)?;
        self.disk = Some(bytes);
        Ok(true)
    }
}

pub fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(suffix);
    s.into()
}

fn read_optional(path: &Path) -> io::Result<Option<Vec<u8>>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Written beside the note and swapped in whole, so a note is never half
/// written -- not by a crash, and not as seen by anything reading it meanwhile.
fn write_whole(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = with_suffix(path, ".tmp");
    std::fs::write(&temp, bytes)?;
    std::fs::rename(&temp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temp);
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A fresh folder per test, removed again when the test is done with it.
    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Folder {
            let dir = std::env::temp_dir().join(format!("noteedit-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Folder(dir)
        }
        fn note(&self) -> PathBuf {
            self.0.join("Notes.txt")
        }
        fn read(&self, suffix: &str) -> Option<String> {
            fs::read_to_string(with_suffix(&self.note(), suffix)).ok()
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn set_read_only(path: &Path, on: bool) {
        let mut p = fs::metadata(path).unwrap().permissions();
        #[allow(clippy::permissions_set_readonly_false)]
        p.set_readonly(on);
        fs::set_permissions(path, p).unwrap();
    }

    #[test]
    fn a_missing_note_is_empty_and_is_only_created_by_typing() {
        let dir = Folder::new("missing");
        let (mut note, text) = NoteFile::open(&dir.note()).unwrap();
        assert!(text.is_empty());

        assert!(!note.save(&[]).unwrap());
        assert!(!dir.note().exists());

        assert!(note.save(&w("milk")).unwrap());
        assert_eq!(dir.read("").as_deref(), Some("milk\n"));
        assert_eq!(dir.read(".bak"), None); // nothing before it to back up
    }

    #[test]
    fn saving_what_is_already_there_writes_nothing() {
        let dir = Folder::new("unchanged");
        fs::write(dir.note(), "milk\n").unwrap();
        let (mut note, text) = NoteFile::open(&dir.note()).unwrap();

        assert!(!note.save(&text).unwrap());
        assert_eq!(dir.read(".bak"), None);
    }

    #[test]
    fn the_backup_is_the_note_from_before_the_edit_not_the_last_autosave() {
        let dir = Folder::new("backup");
        fs::write(dir.note(), "one\n").unwrap();
        let (mut note, _) = NoteFile::open(&dir.note()).unwrap();

        assert!(note.save(&w("one\r\ntwo")).unwrap());
        assert!(note.save(&w("one\r\ntwo\r\nthree")).unwrap());
        assert_eq!(dir.read("").as_deref(), Some("one\ntwo\nthree\n"));
        assert_eq!(dir.read(".bak").as_deref(), Some("one\n"));
    }

    #[test]
    fn a_refused_write_leaves_the_note_alone_and_can_be_retried() {
        let dir = Folder::new("refused");
        fs::write(dir.note(), "one\n").unwrap();
        let (mut note, _) = NoteFile::open(&dir.note()).unwrap();

        set_read_only(&dir.note(), true);
        assert!(note.save(&w("two")).is_err());
        set_read_only(&dir.note(), false);
        assert_eq!(dir.read("").as_deref(), Some("one\n"));
        assert_eq!(dir.read(".tmp"), None); // no temp file left behind

        assert!(note.save(&w("two")).unwrap());
        assert_eq!(dir.read("").as_deref(), Some("two\n"));
        assert_eq!(dir.read(".bak").as_deref(), Some("one\n"));
    }

    #[test]
    fn a_change_made_while_typing_waited_goes_to_the_backup_not_nowhere() {
        let dir = Folder::new("resync");
        fs::write(dir.note(), "[ ] milk\n").unwrap();
        let (mut note, _) = NoteFile::open(&dir.note()).unwrap();
        assert!(note.save(&w("[ ] milk\r\nbread")).unwrap());

        // A checkbox ticked on the sheet while the typing below was unsaved
        fs::write(dir.note(), "[x] milk\nbread\n").unwrap();
        assert!(note.resync().unwrap());
        assert!(!note.resync().unwrap()); // and only once

        assert!(note.save(&w("[ ] milk\r\nbread\r\njam")).unwrap());
        assert_eq!(dir.read("").as_deref(), Some("[ ] milk\nbread\njam\n"));
        assert_eq!(dir.read(".bak").as_deref(), Some("[x] milk\nbread\n"));
    }

    #[test]
    fn an_unreadable_note_is_an_error_and_not_an_empty_one() {
        let dir = Folder::new("unreadable");
        fs::create_dir(dir.note()).unwrap(); // a folder where the note should be
        assert!(NoteFile::open(&dir.note()).is_err());
    }
}
