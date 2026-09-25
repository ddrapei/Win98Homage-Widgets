//! The editing workflow, and nothing else: what happens when the skin says
//! Open, when typing pauses, when the user leaves the box, and when the box is
//! torn down.
//!
//! It sees the box only as an [`Editor`] and the skin only as a [`Skin`] --
//! both defined here, by the side that needs them -- so the whole workflow runs
//! against fakes in the tests below, and does not change when the window code
//! or the Rainmeter API does.  The box talks back through [`EditorEvents`].
//!
//! Every method takes `&self`.  The box calls back into the session while the
//! session is calling the box -- running the skin's bangs can come straight
//! back in as a Close -- so state lives in cells, and no borrow is held across
//! a call out.

use core::cell::{Cell, RefCell};
use std::io;
use std::path::{Path, PathBuf};

use crate::command::{Command, View};
use crate::note_file::NoteFile;
use crate::settings::{Options, Settings};

/// What the session needs from the skin, beyond its options.
pub trait Skin: Options {
    /// Run bangs, e.g. OnCloseAction.
    fn run(&self, action: &str);
    fn log(&self, message: &str);
}

/// The edit box, as the session uses it.
pub trait Editor {
    /// Make the box if it does not exist yet.  False if it cannot be made.
    fn create(&self) -> bool;
    fn is_open(&self) -> bool;
    /// Look, place and autosave delay, from the latest options.
    fn configure(&self, settings: &Settings);
    /// Replace what the box holds, as unmodified and with nothing to undo.
    fn load(&self, text: &[u16]);
    fn text(&self) -> Vec<u16>;
    /// Whether the box holds typing that has not been saved.
    fn is_modified(&self) -> bool;
    fn mark_saved(&self);
    /// Put the box up and give it the keyboard.  With a view, it is a fresh
    /// open: scroll to the view, and put the caret under the pointer.
    fn show(&self, view: Option<View>);
    fn hide(&self);
    /// Ask for the box to be left, as a click outside would: the session hears
    /// back through `EditorEvents::on_leave`, once the current call is over.
    fn request_leave(&self);
    fn destroy(&self);
}

/// What the box tells the session.
pub trait EditorEvents {
    /// The user has left the box: a click outside it, or Escape.
    fn on_leave(&self);
    /// Typing has paused for the autosave delay.
    fn on_pause(&self);
    /// The box is being destroyed, and will not be asked anything again.
    fn on_closing(&self);
}

/// Where things stand, as the measure's string value reports it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Status {
    /// Nothing has happened yet.
    #[default]
    Idle,
    /// The box is up.
    Open,
    /// The box closed and wrote the note.
    Saved,
    /// The box closed with nothing to write.
    Unchanged,
    /// The note could not be written.  The typing is kept in the box, and comes
    /// back the next time it opens.
    WriteError,
    /// Open could not read the note, so did not open.
    ReadError,
    /// Open could not create the box.
    NoWindow,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Idle => "",
            Status::Open => "open",
            Status::Saved => "saved",
            Status::Unchanged => "unchanged",
            Status::WriteError => "write-error",
            Status::ReadError => "read-error",
            Status::NoWindow => "no-window",
        }
    }
}

pub struct Session<E, S> {
    editor: E,
    skin: S,
    /// The note the box is editing, from the Open that loaded it.
    file: RefCell<Option<NoteFile>>,
    status: Cell<Status>,
    on_close: RefCell<String>,
}

impl<E: Editor, S: Skin> Session<E, S> {
    pub fn new(editor: E, skin: S) -> Self {
        Session {
            editor,
            skin,
            file: RefCell::new(None),
            status: Cell::new(Status::Idle),
            on_close: RefCell::new(String::new()),
        }
    }

    pub fn editor(&self) -> &E {
        &self.editor
    }

    pub fn skin(&self) -> &S {
        &self.skin
    }

    pub fn status(&self) -> Status {
        self.status.get()
    }

    pub fn is_open(&self) -> bool {
        self.editor.is_open()
    }

    pub fn run(&self, command: Command) {
        match command {
            Command::Open(view) => self.open(view),
            Command::Close => {
                if self.editor.is_open() {
                    self.editor.request_leave();
                }
            }
        }
    }

    /// The end of the measure: whatever the box holds is written as it goes.
    pub fn shutdown(&self) {
        self.editor.destroy(); // which says on_closing, which saves
    }

    fn open(&self, view: View) {
        let settings = Settings::read(&self.skin);
        // Before anything can fail: the failures are reported through it.
        *self.on_close.borrow_mut() = settings.on_close.clone();

        if !self.editor.create() {
            self.skin.log("could not create the edit box");
            return self.fail(Status::NoWindow);
        }
        let reopening = self.editor.is_open();
        self.editor.configure(&settings);
        if !reopening {
            let pending = self.editor.is_modified()
                && self.file_path().as_deref() == Some(settings.file.as_path());
            let ready = if pending { self.resume() } else { self.load(&settings.file) };
            if !ready {
                return self.fail(Status::ReadError);
            }
        }
        self.editor.show((!reopening).then_some(view));
        self.status.set(Status::Open);
    }

    /// The note into the box, and a fresh file to write it back through.
    fn load(&self, path: &Path) -> bool {
        match NoteFile::open(path) {
            Ok((file, text)) => {
                *self.file.borrow_mut() = Some(file);
                self.editor.load(&text);
                true
            }
            Err(e) => {
                self.skin.log(&format!("cannot read {}: {e}", path.display()));
                false
            }
        }
    }

    /// Typing that could not be saved last time is still in the box, and stays
    /// there -- reloading the note would be losing it a second time.  But the
    /// note may have moved on meanwhile, and the file has to know, or its next
    /// save would throw that change away without a word: see NoteFile::resync.
    fn resume(&self) -> bool {
        let mut file = self.file.borrow_mut();
        let Some(file) = file.as_mut() else { return false };
        match file.resync() {
            Ok(false) => true,
            Ok(true) => {
                self.skin.log(&format!(
                    "{} changed while unsaved typing was waiting; the typing is kept, \
                     and the other version goes to the .bak",
                    file.path().display()
                ));
                true
            }
            Err(e) => {
                self.skin.log(&format!("cannot read {}: {e}", file.path().display()));
                false
            }
        }
    }

    /// An Open that did not open.  The skin has already started editing, so it
    /// is told, just as it would be told of a close.
    fn fail(&self, status: Status) {
        self.status.set(status);
        self.notify();
    }

    /// Leaving the note: save, hide, and tell the skin.
    fn finish(&self) {
        if !self.editor.is_open() {
            return;
        }
        let status = self.save_logged();
        self.status.set(status);
        self.editor.hide();
        self.notify();
    }

    /// Write the box out.  Ok(true) is a write, Ok(false) is nothing to write.
    /// The box stays modified until a write works, which is what makes a failed
    /// one get tried again.
    fn save(&self) -> io::Result<bool> {
        if !self.editor.is_modified() {
            return Ok(false);
        }
        let typed = self.editor.text();
        let wrote = match self.file.borrow_mut().as_mut() {
            Some(file) => file.save(&typed)?,
            None => false,
        };
        self.editor.mark_saved();
        Ok(wrote)
    }

    fn save_logged(&self) -> Status {
        match self.save() {
            Ok(true) => Status::Saved,
            Ok(false) => Status::Unchanged,
            Err(e) => {
                let path = self.file_path().unwrap_or_default();
                self.skin.log(&format!("cannot write {}: {e}", path.display()));
                Status::WriteError
            }
        }
    }

    /// OnCloseAction.  Copied out first: the bangs may well come straight back
    /// in here.
    fn notify(&self) {
        let action = self.on_close.borrow().clone();
        if !action.is_empty() {
            self.skin.run(&action);
        }
    }

    fn file_path(&self) -> Option<PathBuf> {
        self.file.borrow().as_ref().map(|f| f.path().to_owned())
    }
}

impl<E: Editor, S: Skin> EditorEvents for Session<E, S> {
    fn on_leave(&self) {
        self.finish();
    }

    fn on_pause(&self) {
        self.save_logged(); // autosave: the box stays open, the status with it
    }

    fn on_closing(&self) {
        self.save_logged();
    }
}

#[cfg(test)]
mod tests {
    //! The workflow against a fake box and a fake skin, and a real note in a
    //! temporary folder.
    use super::*;
    use crate::settings::tests::Table;
    use std::fs;

    #[derive(Default)]
    struct FakeEditor {
        cannot_create: bool,
        created: Cell<bool>,
        open: Cell<bool>,
        text: RefCell<Vec<u16>>,
        modified: Cell<bool>,
        shown_with: Cell<Option<Option<View>>>,
        leave_requested: Cell<bool>,
    }

    impl FakeEditor {
        fn type_text(&self, s: &str) {
            self.text.borrow_mut().extend(s.encode_utf16());
            self.modified.set(true);
        }
        fn contents(&self) -> String {
            String::from_utf16_lossy(&self.text.borrow())
        }
    }

    impl Editor for FakeEditor {
        fn create(&self) -> bool {
            self.created.set(!self.cannot_create);
            !self.cannot_create
        }
        fn is_open(&self) -> bool { self.open.get() }
        fn configure(&self, _: &Settings) {}
        fn load(&self, text: &[u16]) {
            *self.text.borrow_mut() = text.to_vec();
            self.modified.set(false);
        }
        fn text(&self) -> Vec<u16> { self.text.borrow().clone() }
        fn is_modified(&self) -> bool { self.modified.get() }
        fn mark_saved(&self) { self.modified.set(false) }
        fn show(&self, view: Option<View>) {
            self.open.set(true);
            self.shown_with.set(Some(view));
        }
        fn hide(&self) { self.open.set(false) }
        fn request_leave(&self) { self.leave_requested.set(true) }
        fn destroy(&self) { self.open.set(false) }
    }

    struct FakeSkin {
        options: Table,
        ran: RefCell<Vec<String>>,
        logged: RefCell<Vec<String>>,
    }

    impl Options for FakeSkin {
        fn string(&self, o: &str, d: &str) -> String { self.options.string(o, d) }
        fn action(&self, o: &str) -> String { self.options.action(o) }
        fn number(&self, o: &str, d: f64) -> f64 { self.options.number(o, d) }
        fn path(&self, _: &str) -> PathBuf { PathBuf::from(self.options.string("File", "")) }
    }

    impl Skin for FakeSkin {
        fn run(&self, action: &str) { self.ran.borrow_mut().push(action.to_owned()) }
        fn log(&self, message: &str) { self.logged.borrow_mut().push(message.to_owned()) }
    }

    /// A session over a note in its own temporary folder.
    struct Rig {
        session: Session<FakeEditor, FakeSkin>,
        dir: PathBuf,
    }

    impl Rig {
        fn new(name: &str, note: Option<&str>) -> Rig {
            Rig::with_editor(name, note, FakeEditor::default())
        }
        fn with_editor(name: &str, note: Option<&str>, editor: FakeEditor) -> Rig {
            let dir = std::env::temp_dir().join(format!("noteedit-session-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            let file = dir.join("Notes.txt");
            if let Some(text) = note {
                fs::write(&file, text).unwrap();
            }
            let file: &'static str = Box::leak(file.to_string_lossy().into_owned().into_boxed_str());
            let skin = FakeSkin {
                options: Table::with(&[("File", file), ("OnCloseAction", "!Closed")]),
                ran: RefCell::new(Vec::new()),
                logged: RefCell::new(Vec::new()),
            };
            Rig { session: Session::new(editor, skin), dir }
        }
        fn open(&self) {
            self.session.run(Command::Open(View { line: 3, rows: 1 }));
        }
        fn box_(&self) -> &FakeEditor {
            self.session.editor()
        }
        fn note(&self) -> Option<String> {
            fs::read_to_string(self.dir.join("Notes.txt")).ok()
        }
        fn closed_count(&self) -> usize {
            self.session.skin().ran.borrow().iter().filter(|a| *a == "!Closed").count()
        }
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn open_puts_the_note_in_the_box_at_the_sheets_view() {
        let rig = Rig::new("open", Some("[ ] milk\n"));
        rig.open();
        assert_eq!(rig.session.status(), Status::Open);
        assert_eq!(rig.box_().contents(), "[ ] milk\r\n");
        assert_eq!(rig.box_().shown_with.get(), Some(Some(View { line: 3, rows: 1 })));
        assert_eq!(rig.closed_count(), 0);
    }

    #[test]
    fn leaving_saves_hides_and_tells_the_skin() {
        let rig = Rig::new("leave", Some("[ ] milk\n"));
        rig.open();
        rig.box_().type_text("bread");
        rig.session.on_leave();
        assert_eq!(rig.session.status(), Status::Saved);
        assert!(!rig.session.is_open());
        assert_eq!(rig.note().as_deref(), Some("[ ] milk\nbread\n"));
        assert_eq!(rig.closed_count(), 1);
    }

    #[test]
    fn leaving_with_nothing_typed_writes_nothing() {
        let rig = Rig::new("unchanged", Some("[ ] milk\n"));
        rig.open();
        rig.session.on_leave();
        assert_eq!(rig.session.status(), Status::Unchanged);
        assert_eq!(rig.closed_count(), 1);
        assert!(!rig.dir.join("Notes.txt.bak").exists());
    }

    #[test]
    fn leaving_a_box_that_is_not_open_does_nothing() {
        let rig = Rig::new("not-open", Some("x\n"));
        rig.session.on_leave();
        assert_eq!(rig.session.status(), Status::Idle);
        assert_eq!(rig.closed_count(), 0);
    }

    #[test]
    fn a_pause_saves_and_leaves_the_box_open() {
        let rig = Rig::new("pause", Some("a\n"));
        rig.open();
        rig.box_().type_text("b");
        rig.session.on_pause();
        assert_eq!(rig.note().as_deref(), Some("a\nb\n"));
        assert!(rig.session.is_open());
        assert_eq!(rig.session.status(), Status::Open);
        assert_eq!(rig.closed_count(), 0);
    }

    #[test]
    fn shutting_down_with_the_box_open_saves_first() {
        let rig = Rig::new("shutdown", Some("a\n"));
        rig.open();
        rig.box_().type_text("b");
        rig.session.on_closing(); // what destroying the real box says
        rig.session.shutdown();
        assert_eq!(rig.note().as_deref(), Some("a\nb\n"));
    }

    #[test]
    fn close_asks_the_box_to_be_left_only_if_it_is_open() {
        let rig = Rig::new("close", Some("a\n"));
        rig.session.run(Command::Close);
        assert!(!rig.box_().leave_requested.get());
        rig.open();
        rig.session.run(Command::Close);
        assert!(rig.box_().leave_requested.get());
    }

    #[test]
    fn opening_an_open_box_does_not_reload_it() {
        let rig = Rig::new("reopen", Some("a\n"));
        rig.open();
        rig.box_().type_text("b");
        rig.open();
        assert_eq!(rig.box_().contents(), "a\r\nb");
        assert_eq!(rig.box_().shown_with.get(), Some(None));
    }

    #[test]
    fn a_box_that_cannot_be_made_is_reported_as_a_close() {
        let editor = FakeEditor { cannot_create: true, ..FakeEditor::default() };
        let rig = Rig::with_editor("no-window", Some("a\n"), editor);
        rig.open();
        assert_eq!(rig.session.status(), Status::NoWindow);
        assert!(!rig.session.is_open());
        assert_eq!(rig.closed_count(), 1);
    }

    #[test]
    fn a_note_that_cannot_be_read_is_reported_and_not_shown() {
        let rig = Rig::new("unreadable", None);
        fs::create_dir(rig.dir.join("Notes.txt")).unwrap(); // a folder, not a file
        rig.open();
        assert_eq!(rig.session.status(), Status::ReadError);
        assert!(!rig.session.is_open());
        assert_eq!(rig.closed_count(), 1);
        assert_eq!(rig.session.skin().logged.borrow().len(), 1);
    }

    #[test]
    fn a_refused_write_keeps_the_typing_for_next_time() {
        let rig = Rig::new("refused", Some("a\n"));
        let note = rig.dir.join("Notes.txt");
        rig.open();
        rig.box_().type_text("b");

        let mut perms = fs::metadata(&note).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&note, perms.clone()).unwrap();
        rig.session.on_leave();
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&note, perms).unwrap();

        assert_eq!(rig.session.status(), Status::WriteError);
        assert!(rig.box_().is_modified());
        assert_eq!(rig.closed_count(), 1);

        rig.open(); // the typing is still there, not reloaded over
        assert_eq!(rig.box_().contents(), "a\r\nb");
        rig.session.on_leave();
        assert_eq!(rig.session.status(), Status::Saved);
        assert_eq!(rig.note().as_deref(), Some("a\nb\n"));
    }

    #[test]
    fn statuses_read_the_way_the_skin_expects() {
        let all = [
            (Status::Idle, ""), (Status::Open, "open"), (Status::Saved, "saved"),
            (Status::Unchanged, "unchanged"), (Status::WriteError, "write-error"),
            (Status::ReadError, "read-error"), (Status::NoWindow, "no-window"),
        ];
        for (status, text) in all {
            assert_eq!(status.as_str(), text);
        }
    }
}
