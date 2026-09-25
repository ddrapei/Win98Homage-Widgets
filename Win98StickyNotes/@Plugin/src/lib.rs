//! NoteEdit -- a Rainmeter plugin that edits a text file the way a sticky note
//! does.
//!
//! InputText, the plugin Rainmeter ships, is a prompt: it hands its text back
//! only when Enter is pressed, and a click anywhere else throws the typing away.
//! A note wants the opposite -- Enter is a new line, and leaving is saving.  So
//! this plugin owns the file as well as the box:
//!
//!   Open     puts a multi-line edit box over the paper, holding the file as it
//!            is on disk, with the caret wherever the pointer is
//!   typing   is written back a moment after it pauses (AutoSave), so a crash
//!            or a power cut costs a second of typing and not a session
//!   leaving  -- a click anywhere that is not the box, Escape, another window
//!            coming forward -- saves and hides the box, then runs
//!            OnCloseAction so the skin can re-read the file
//!
//! # Using it from a skin
//!
//! Options, all read when the box opens so the skin can change them any time:
//!
//!   X, Y, W, H        the box, in skin pixels; formulas allowed
//!   Padding           l,t,r,b inside the box, where the text may not go
//!   SolidColor        the paper;  FontColor  the ink  (R,G,B or RRGGBB)
//!   FontFace, FontSize, StringStyle (Normal/Bold/Italic/BoldItalic), AntiAlias
//!   File              the note, relative to the skin's folder
//!   AutoSave          ms of quiet before the typing is written; 0 = on close only
//!   OnCloseAction     bangs to run once the box has closed
//!
//! Commands:  Open [line [rows]]   and   Close        (see `command`)
//!
//! OnCloseAction runs after every Open that does not leave the box open --
//! a close, or an Open that failed -- so a skin waiting on it always hears.
//! The string value says where things stand: open, saved, unchanged,
//! write-error, read-error or no-window (see `session::Status`).
//!
//! # Where things are
//!
//! One job per module.  The arrows are who uses whom; nothing points back up.
//!
//! ```text
//!   plugin ──► session ──► note_file ──► codec
//!     │          │  ▲
//!     │          │  └──── Editor, Skin: traits the session defines, and
//!     │          │        the two adapters below implement
//!     │          ▼
//!     │        settings, command
//!     ├──► win32::Popup      (the Editor: the box on screen)
//!     └──► rainmeter         (the Skin: options, bangs, the log)
//! ```
//!
//!   plugin       the six functions Rainmeter calls, each handed to a Session
//!   session      the editing workflow: open, save as you type, save and close
//!                on leaving -- and the Editor, Skin and Status it works in
//!   command      the bangs a skin can send: Open, Close
//!   settings     the measure's options, read into plain values
//!   note_file    the note on disk: read, write whole, keep the .bak
//!   codec        the note's bytes to the box's UTF-16 and back
//!   navigation   where lines and words start in the box's text
//!   win32        the box on screen: popup, edit control, font, brush, class
//!   rainmeter    Rainmeter's API: options, bangs, the log
//!   wide         UTF-16 strings for both C APIs

mod codec;
mod command;
mod navigation;
mod note_file;
mod plugin;
mod rainmeter;
mod session;
mod settings;
mod wide;
mod win32;
