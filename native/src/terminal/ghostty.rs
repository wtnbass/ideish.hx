//! The emulator behind terminal.rs: libghostty-vt on a portable-pty PTY.
//!
//! libghostty-vt types are !Send, so one thread creates and owns the
//! emulator, the render state and the key encoder for a terminal's lifetime.
//! A reader thread forwards what the PTY prints and a waiter thread reports
//! the exit; both talk to it through the same channel as Steel does.

use std::{
    cell::RefCell,
    io::{Read, Write},
    sync::{
        mpsc::{self, Receiver},
        Arc, Mutex,
    },
    thread,
};

use libghostty_vt::{
    key::{self, Action, Key, Mods, OptionAsAlt},
    paste,
    render::{CellIterator, CellIteration, Dirty, RowIterator},
    screen::{CellContentTag, CellWide},
    style::{StyleColor, Underline},
    terminal::{Mode, ScrollViewport},
    Error, RenderState, Terminal,
};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};

use super::{
    Input, Run, Screen, Spawned, BOLD, FAINT, INVERSE, ITALIC, RGB_BASE, STRIKETHROUGH, UNDERLINE,
};

const SCROLLBACK: usize = 10_000;

fn pty_size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

pub(super) fn spawn(
    program: &str,
    args: &[&str],
    cwd: &str,
    cols: u16,
    rows: u16,
    screen: Arc<Mutex<Screen>>,
) -> Result<Spawned, String> {
    let pair = native_pty_system()
        .openpty(pty_size(cols, rows))
        .map_err(|err| format!("could not open a pty: {err}"))?;

    let mut command = CommandBuilder::new(program);
    command.args(args);
    command.cwd(cwd);
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    let mut child = pair
        .slave
        .spawn_command(command)
        .map_err(|err| format!("{program}: {err}"))?;
    // the child holds the slave now; keeping it open here would hide its exit
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|err| format!("could not read the pty: {err}"))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|err| format!("could not write the pty: {err}"))?;
    let killer = Mutex::new(child.clone_killer());

    let (input, rx) = mpsc::channel();

    let output = input.clone();
    thread::spawn(move || {
        let mut buf = [0u8; 64 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if output.send(Input::Output(buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let exited = input.clone();
    thread::spawn(move || {
        let code = child.wait().map(|s| s.exit_code() as i32).unwrap_or(-1);
        let _ = exited.send(Input::Exited(code));
    });

    let master = pair.master;
    thread::spawn(move || run(rx, master, writer, cols, rows, screen));

    Ok(Spawned {
        input,
        kill: Box::new(move || {
            let _ = killer.lock().unwrap().kill();
        }),
    })
}

fn run(
    rx: Receiver<Input>,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    cols: u16,
    rows: u16,
    screen: Arc<Mutex<Screen>>,
) {
    // declared before the terminal: its pty-write callback borrows it
    let writer = RefCell::new(writer);
    let write = |bytes: &[u8]| {
        let mut w = writer.borrow_mut();
        let _ = w.write_all(bytes).and_then(|_| w.flush());
    };

    let Ok(mut term) = Terminal::new(cols, rows) else { return };
    let _ = term.set_scrollback_max_lines(Some(SCROLLBACK));
    // answers to queries (cursor position, device attributes) go back to the program
    if term.on_pty_write(|_, data| write(data)).is_err() {
        return;
    }
    let (Ok(mut state), Ok(mut row_iter), Ok(mut cell_iter), Ok(mut encoder), Ok(mut event)) = (
        RenderState::new(),
        RowIterator::new(),
        CellIterator::new(),
        key::Encoder::new(),
        key::Event::new(),
    ) else {
        return;
    };
    let mut size = (cols, rows);
    let mut encoded = Vec::new();

    while let Ok(first) = rx.recv() {
        // take everything queued, then publish once
        let mut next = Some(first);
        while let Some(input) = next {
            match input {
                Input::Output(bytes) => term.vt_write(&bytes),
                Input::Key { key, mods, text } => {
                    term.scroll_viewport(ScrollViewport::Bottom);
                    if set_key_event(&mut event, &key, mods, text) {
                        encoder
                            .set_options_from_terminal(&term)
                            .set_macos_option_as_alt(OptionAsAlt::True);
                        encoded.clear();
                        if encoder.encode_to_vec(&event, &mut encoded).is_ok() {
                            write(&encoded);
                        }
                    }
                }
                Input::Paste(text) => {
                    term.scroll_viewport(ScrollViewport::Bottom);
                    let bracketed = term.mode(Mode::BRACKETED_PASTE).unwrap_or(false);
                    if let Some(bytes) = encode_paste(text, bracketed) {
                        write(&bytes);
                    }
                }
                Input::Resize(c, r) => {
                    if (c, r) != size {
                        size = (c, r);
                        let _ = term.resize(c, r, 8, 16);
                        let _ = master.resize(pty_size(c, r));
                    }
                }
                Input::Scroll(delta) => term.scroll_viewport(ScrollViewport::Delta(delta)),
                Input::Exited(code) => {
                    let mut screen = screen.lock().unwrap();
                    screen.exit = Some(code);
                    screen.changed = true;
                }
                Input::Stop => return,
            }
            next = rx.try_recv().ok();
        }
        publish(&term, &mut state, &mut row_iter, &mut cell_iter, &screen);
    }
}

fn publish<'alloc>(
    term: &Terminal<'alloc, '_>,
    state: &mut RenderState<'alloc>,
    row_iter: &mut RowIterator<'alloc>,
    cell_iter: &mut CellIterator<'alloc>,
    screen: &Mutex<Screen>,
) {
    let Ok(snapshot) = state.update(term) else { return };
    if matches!(snapshot.dirty(), Ok(Dirty::Clean)) {
        return;
    }
    let mut rows = Vec::new();
    if let Ok(mut iteration) = row_iter.update(&snapshot) {
        while let Some(row) = iteration.next() {
            let mut runs = Vec::new();
            if let Ok(mut cells) = cell_iter.update(row) {
                let mut col = 0;
                while let Some(cell) = cells.next() {
                    push_cell(&mut runs, cell, col);
                    col += 1;
                }
            }
            rows.push(runs);
            let _ = row.set_dirty(false);
        }
    }
    let cursor = match snapshot.cursor_visible() {
        Ok(true) => snapshot
            .cursor_viewport()
            .ok()
            .flatten()
            .map(|c| (c.x, c.y)),
        _ => None,
    };
    let _ = snapshot.set_dirty(Dirty::Clean);

    let mut screen = screen.lock().unwrap();
    screen.rows = rows;
    screen.cursor = cursor;
    screen.title = term.title().unwrap_or("").to_string();
    screen.changed = true;
}

fn color(c: StyleColor) -> isize {
    match c {
        StyleColor::None => -1,
        StyleColor::Palette(index) => index.0 as isize,
        StyleColor::Rgb(rgb) => {
            RGB_BASE + ((rgb.r as isize) << 16 | (rgb.g as isize) << 8 | rgb.b as isize)
        }
    }
}

/// Appends the cell at col to the row, extending the last run when the style matches
fn push_cell(runs: &mut Vec<Run>, cell: &CellIteration<'_, '_>, col: u16) {
    let Ok(raw) = cell.raw_cell() else { return };
    // the right half of a wide character: the left half already covers it
    if matches!(raw.wide(), Ok(CellWide::SpacerTail)) {
        return;
    }
    let style = match cell.has_styling() {
        Ok(true) => cell.style().ok(),
        _ => None,
    };
    let (fg, mut bg, flags) = match style {
        Some(s) => {
            let mut flags = 0;
            if s.bold {
                flags |= BOLD;
            }
            if s.italic {
                flags |= ITALIC;
            }
            if s.faint {
                flags |= FAINT;
            }
            if s.underline != Underline::None {
                flags |= UNDERLINE;
            }
            if s.inverse {
                flags |= INVERSE;
            }
            if s.strikethrough {
                flags |= STRIKETHROUGH;
            }
            (color(s.fg_color), color(s.bg_color), flags)
        }
        None => (-1, -1, 0),
    };
    // a cell with no text can carry a background of its own (erased with a colour)
    if bg == -1 {
        bg = match raw.content_tag() {
            Ok(CellContentTag::BgColorPalette) => {
                raw.bg_color_palette().map_or(-1, |i| i.0 as isize)
            }
            Ok(CellContentTag::BgColorRgb) => raw
                .bg_color_rgb()
                .map_or(-1, |rgb| color(StyleColor::Rgb(rgb))),
            _ => -1,
        };
    }

    let invisible = style.is_some_and(|s| s.invisible);
    let graphemes = cell.graphemes().unwrap_or_default();
    let wide = matches!(raw.wide(), Ok(CellWide::Wide));
    let text: String = if graphemes.is_empty() || invisible {
        if wide { "  " } else { " " }.to_string()
    } else {
        graphemes.into_iter().collect()
    };

    match runs.last_mut() {
        // a wide character starts a run of its own, so the next run's column
        // never depends on how Steel measures it
        Some(last) if !wide && last.fg == fg && last.bg == bg && last.flags == flags && !last.wide => {
            last.text.push_str(&text)
        }
        _ => runs.push(Run {
            col,
            wide,
            text,
            fg,
            bg,
            flags,
        }),
    }
}

fn encode_paste(text: String, bracketed: bool) -> Option<Vec<u8>> {
    let mut data = text.into_bytes();
    let mut buf = vec![0u8; data.len() + 16];
    let written = match paste::encode(&mut data, bracketed, &mut buf) {
        Ok(n) => n,
        Err(Error::OutOfSpace { required }) => {
            buf.resize(required, 0);
            paste::encode(&mut data, bracketed, &mut buf).ok()?
        }
        Err(_) => return None,
    };
    buf.truncate(written);
    Some(buf)
}

/// The physical key and its unshifted character on a US layout
fn char_key(c: char) -> (Key, char) {
    const SHIFTED: &str = ")!@#$%^&*(";
    let base = match c {
        'A'..='Z' => c.to_ascii_lowercase(),
        _ => match SHIFTED.find(c) {
            Some(digit) => char::from(b'0' + digit as u8),
            None => match c {
                '_' => '-',
                '+' => '=',
                '{' => '[',
                '}' => ']',
                '|' => '\\',
                ':' => ';',
                '"' => '\'',
                '~' => '`',
                '<' => ',',
                '>' => '.',
                '?' => '/',
                _ => c,
            },
        },
    };
    let offset = |from: char, first: Key| Key::try_from(first as i32 + (base as i32 - from as i32));
    let key = match base {
        'a'..='z' => offset('a', Key::A).unwrap_or(Key::Unidentified),
        '0'..='9' => offset('0', Key::Digit0).unwrap_or(Key::Unidentified),
        ' ' => Key::Space,
        '-' => Key::Minus,
        '=' => Key::Equal,
        '[' => Key::BracketLeft,
        ']' => Key::BracketRight,
        '\\' => Key::Backslash,
        ';' => Key::Semicolon,
        '\'' => Key::Quote,
        '`' => Key::Backquote,
        ',' => Key::Comma,
        '.' => Key::Period,
        '/' => Key::Slash,
        _ => Key::Unidentified,
    };
    (key, base)
}

fn named_key(name: &str) -> Option<Key> {
    Some(match name {
        "enter" => Key::Enter,
        "tab" => Key::Tab,
        "backspace" => Key::Backspace,
        "escape" => Key::Escape,
        "left" => Key::ArrowLeft,
        "right" => Key::ArrowRight,
        "up" => Key::ArrowUp,
        "down" => Key::ArrowDown,
        "home" => Key::Home,
        "end" => Key::End,
        "page-up" => Key::PageUp,
        "page-down" => Key::PageDown,
        "delete" => Key::Delete,
        "insert" => Key::Insert,
        _ => {
            let n: i32 = name.strip_prefix('f')?.parse().ok()?;
            if !(1..=24).contains(&n) {
                return None;
            }
            Key::try_from(Key::F1 as i32 + n - 1).ok()?
        }
    })
}

/// Fills the reused event; #f for a key it does not know
fn set_key_event(event: &mut key::Event<'_>, name: &str, helix_mods: u8, text: Option<String>) -> bool {
    let mut mods = Mods::empty();
    if helix_mods & 1 != 0 {
        mods |= Mods::SHIFT;
    }
    if helix_mods & 2 != 0 {
        mods |= Mods::CTRL;
    }
    if helix_mods & 4 != 0 {
        mods |= Mods::ALT;
    }
    if helix_mods & 8 != 0 {
        mods |= Mods::SUPER;
    }

    let mut chars = name.chars();
    let (key, unshifted, text) = match (chars.next(), chars.next()) {
        (Some(c), None) => {
            let (key, base) = char_key(c);
            (key, Some(base), text.or_else(|| Some(c.to_string())))
        }
        _ => match named_key(name) {
            Some(key) => (key, None, None),
            None => return false,
        },
    };
    // shift went into the character itself ("A", "!"), so the encoder must not add it again
    let consumed = match unshifted {
        Some(base) if mods.contains(Mods::SHIFT) && text.as_deref() != Some(&base.to_string()) => {
            Mods::SHIFT
        }
        _ => Mods::empty(),
    };

    event
        .set_action(Action::Press)
        .set_key(key)
        .set_mods(mods)
        .set_consumed_mods(consumed)
        .set_composing(false)
        .set_utf8(text)
        .set_unshifted_codepoint(unshifted.unwrap_or('\0'));
    true
}
