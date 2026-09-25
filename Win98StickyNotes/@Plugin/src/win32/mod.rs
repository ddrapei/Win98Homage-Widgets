//! The box on screen, in Win32 -- the one part of the plugin that knows it runs
//! on Windows.  The rest of the crate uses [`Popup`] and nothing else here.
//!
//!   popup   the box: window, messages, and the session's Editor
//!   edit    the EDIT control inside it, and the note's keys
//!   gdi     the font and brush it paints with, deleted when dropped
//!   class   the window class, registered while a popup needs it
//!   sys     the raw declarations

mod class;
mod edit;
mod gdi;
mod popup;
mod sys;

pub use popup::Popup;
