//! Terminal panes: a shell on a PTY.
//!
//! Each terminal runs on its own thread, which owns the emulator and feeds it
//! what the PTY prints. After each batch of input the thread publishes the
//! screen as rows of styled runs; Helix's main thread takes them from a tick,
//! so drawing never touches the emulator.
//!
//! This file is the contract with Steel and does not depend on the emulator.
//! The emulator (alacritty_terminal) is in `alacritty.rs`, and the bytes each
//! key sends are worked out in `keys.rs`.

use std::sync::{mpsc::Sender, Arc, Mutex};

use abi_stable::std_types::{RString, RVec};
use steel::{
    rvals::Custom,
    steel_vm::ffi::{FFIModule, FFIValue, IntoFFIVal, RegisterFFIFn},
};

mod alacritty;
mod keys;

pub fn register(module: &mut FFIModule) {
    module
        .register_fn("terminal-spawn", terminal_spawn)
        .register_fn("terminal-poll!", TerminalHandle::poll)
        .register_fn("terminal-rows", TerminalHandle::rows)
        .register_fn("terminal-cursor", TerminalHandle::cursor)
        .register_fn("terminal-title", TerminalHandle::title)
        .register_fn("terminal-exit-code", TerminalHandle::exit_code)
        .register_fn("terminal-key!", TerminalHandle::key)
        .register_fn("terminal-paste!", TerminalHandle::paste)
        .register_fn("terminal-resize!", TerminalHandle::resize)
        .register_fn("terminal-scroll!", TerminalHandle::scroll)
        .register_fn("terminal-kill!", TerminalHandle::kill);
}

/// Text with one style, starting at column col. Colours: -1 is the default,
/// 0-255 a palette index and RGB_BASE + 0xRRGGBB a direct colour.
pub(crate) struct Run {
    pub col: u16,
    /// Holds one wide character and nothing else
    pub wide: bool,
    pub text: String,
    pub fg: isize,
    pub bg: isize,
    pub flags: isize,
}

pub(crate) const RGB_BASE: isize = 0x100_0000;

pub(crate) const BOLD: isize = 1;
pub(crate) const ITALIC: isize = 2;
pub(crate) const FAINT: isize = 4;
pub(crate) const UNDERLINE: isize = 8;
pub(crate) const INVERSE: isize = 16;
pub(crate) const STRIKETHROUGH: isize = 32;

/// What the emulator thread last published.
#[derive(Default)]
pub(crate) struct Screen {
    pub rows: Vec<Vec<Run>>,
    /// Column and row of the cursor, when it is shown in the viewport
    pub cursor: Option<(u16, u16)>,
    pub title: String,
    /// Set by each publish, cleared by poll!
    pub changed: bool,
    pub exit: Option<i32>,
}

/// Messages to the emulator thread.
pub(crate) enum Input {
    Output(Vec<u8>),
    /// key: a name ("enter", "page-up", "f5"...) or one character. mods: Helix's
    /// bits (1 shift, 2 ctrl, 4 alt, 8 super). text: what the key types, if anything.
    Key {
        key: String,
        mods: u8,
        text: Option<String>,
    },
    Paste(String),
    Resize(u16, u16),
    /// Lines to move the viewport by, negative is up
    Scroll(isize),
    Exited(i32),
    Stop,
}

pub(crate) struct Spawned {
    pub input: Sender<Input>,
    pub kill: Box<dyn Fn() + Send + Sync>,
}

pub struct TerminalHandle {
    input: Sender<Input>,
    screen: Arc<Mutex<Screen>>,
    kill: Box<dyn Fn() + Send + Sync>,
}

impl Custom for TerminalHandle {}

fn size(n: isize) -> u16 {
    n.clamp(1, u16::MAX as isize) as u16
}

/// args: newline-separated. Returns the terminal, or an error message string.
fn terminal_spawn(program: String, args: String, cwd: String, cols: isize, rows: isize) -> FFIValue {
    let screen = Arc::new(Mutex::new(Screen::default()));
    let args: Vec<&str> = args.split('\n').filter(|a| !a.is_empty()).collect();
    match alacritty::spawn(&program, &args, &cwd, size(cols), size(rows), Arc::clone(&screen)) {
        Ok(Spawned { input, kill }) => TerminalHandle {
            input,
            screen,
            kill,
        }
        .into_ffi_val()
        .unwrap_or(FFIValue::BoolV(false)),
        Err(message) => FFIValue::StringV(RString::from(message)),
    }
}

fn int(n: isize) -> FFIValue {
    FFIValue::IntV(n)
}

impl TerminalHandle {
    fn send(&self, input: Input) {
        let _ = self.input.send(input);
    }

    /// #t when the screen changed since the last call.
    fn poll(&self) -> bool {
        let mut screen = self.screen.lock().unwrap();
        std::mem::replace(&mut screen.changed, false)
    }

    /// The viewport: a list of rows, each a list of runs (col text fg bg flags);
    /// Steel receives FFI vectors as lists.
    /// col comes from the emulator, so wide characters cannot shift what follows.
    fn rows(&self) -> FFIValue {
        let screen = self.screen.lock().unwrap();
        FFIValue::Vector(
            screen
                .rows
                .iter()
                .map(|runs| {
                    FFIValue::Vector(
                        runs.iter()
                            .map(|run| {
                                FFIValue::Vector(RVec::from(vec![
                                    int(run.col as isize),
                                    FFIValue::StringV(RString::from(run.text.as_str())),
                                    int(run.fg),
                                    int(run.bg),
                                    int(run.flags),
                                ]))
                            })
                            .collect::<RVec<_>>(),
                    )
                })
                .collect::<RVec<_>>(),
        )
    }

    /// (column row) of the cursor, or #f while it is hidden.
    fn cursor(&self) -> FFIValue {
        match self.screen.lock().unwrap().cursor {
            Some((x, y)) => FFIValue::Vector(RVec::from(vec![int(x as isize), int(y as isize)])),
            None => FFIValue::BoolV(false),
        }
    }

    /// The title the program set, or "".
    fn title(&self) -> String {
        self.screen.lock().unwrap().title.clone()
    }

    /// #f while the program runs, its exit code once it has stopped.
    fn exit_code(&self) -> FFIValue {
        match self.screen.lock().unwrap().exit {
            Some(code) => int(code as isize),
            None => FFIValue::BoolV(false),
        }
    }

    /// text: "" when the key types nothing.
    fn key(&self, key: String, mods: isize, text: String) {
        self.send(Input::Key {
            key,
            mods: mods as u8,
            text: (!text.is_empty()).then_some(text),
        });
    }

    fn paste(&self, text: String) {
        self.send(Input::Paste(text));
    }

    fn resize(&self, cols: isize, rows: isize) {
        self.send(Input::Resize(size(cols), size(rows)));
    }

    fn scroll(&self, delta: isize) {
        self.send(Input::Scroll(delta));
    }

    fn kill(&self) {
        self.send(Input::Stop);
        (self.kill)();
    }
}

impl Drop for TerminalHandle {
    fn drop(&mut self) {
        self.kill();
    }
}
