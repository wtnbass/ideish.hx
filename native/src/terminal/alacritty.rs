//! The emulator behind terminal.rs: alacritty_terminal on a portable-pty PTY.
//!
//! One thread creates and owns the emulator for a terminal's lifetime. A
//! reader thread forwards what the PTY prints and a waiter thread reports the
//! exit; both talk to it through the same channel as Steel does.

use std::{
    cell::RefCell,
    io::{Read, Write},
    rc::Rc,
    sync::{
        mpsc::{self, Receiver, RecvTimeoutError},
        Arc, Mutex,
    },
    thread,
    time::Instant,
};

use alacritty_terminal::{
    event::{Event, EventListener, WindowSize},
    grid::{Dimensions, Scroll},
    index::{Column, Line},
    term::{
        cell::{Cell, Flags},
        Config, Osc52, TermDamage, TermMode,
    },
    vte::ansi::{Color, NamedColor, Processor},
    Term,
};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};

use super::{
    keys, Input, Run, Screen, Spawned, BOLD, FAINT, INVERSE, ITALIC, RGB_BASE, STRIKETHROUGH,
    UNDERLINE,
};

const SCROLLBACK: usize = 10_000;

/// Cell size reported to programs that ask for the text area in pixels
const CELL_WIDTH: u16 = 8;
const CELL_HEIGHT: u16 = 16;

fn pty_size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

#[derive(Clone, Copy, PartialEq)]
struct Size {
    cols: u16,
    rows: u16,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.screen_lines()
    }

    fn screen_lines(&self) -> usize {
        self.rows as usize
    }

    fn columns(&self) -> usize {
        self.cols as usize
    }
}

/// Queues what the emulator reports; the thread handles it after each batch
#[derive(Clone, Default)]
struct Listener(Rc<RefCell<Vec<Event>>>);

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        self.0.borrow_mut().push(event);
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
    let size = Size { cols, rows };
    thread::spawn(move || run(rx, master, writer, size, screen));

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
    mut writer: Box<dyn Write + Send>,
    mut size: Size,
    screen: Arc<Mutex<Screen>>,
) {
    let mut write = |bytes: &[u8]| {
        let _ = writer.write_all(bytes).and_then(|_| writer.flush());
    };

    let config = Config {
        scrolling_history: SCROLLBACK,
        kitty_keyboard: true,
        osc52: Osc52::Disabled,
        ..Config::default()
    };
    let listener = Listener::default();
    let mut term = Term::new(config, &size, listener.clone());
    let mut parser: Processor = Processor::new();
    let mut title = String::new();

    loop {
        // a synchronized update (DECSET 2026) holds the output back until it
        // ends or its deadline passes
        let first = match parser.sync_timeout().sync_timeout() {
            Some(deadline) => {
                match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                    Ok(input) => Some(input),
                    Err(RecvTimeoutError::Timeout) => {
                        parser.stop_sync(&mut term);
                        None
                    }
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            None => match rx.recv() {
                Ok(input) => Some(input),
                Err(_) => return,
            },
        };

        // take everything queued, then publish once
        let mut next = first;
        while let Some(input) = next {
            match input {
                Input::Output(bytes) => parser.advance(&mut term, &bytes),
                Input::Key { key, mods, text } => {
                    term.scroll_display(Scroll::Bottom);
                    let bytes = keys::encode(&key, mods, text.as_deref(), *term.mode());
                    if !bytes.is_empty() {
                        write(&bytes);
                    }
                }
                Input::Paste(text) => {
                    term.scroll_display(Scroll::Bottom);
                    let bracketed = term.mode().contains(TermMode::BRACKETED_PASTE);
                    write(&encode_paste(&text, bracketed));
                }
                Input::Resize(cols, rows) => {
                    let new = Size { cols, rows };
                    if new != size {
                        size = new;
                        term.resize(size);
                        let _ = master.resize(pty_size(cols, rows));
                    }
                }
                Input::Scroll(delta) => {
                    // ideish counts up as negative, alacritty as positive
                    let lines = i32::try_from(-delta).unwrap_or(0);
                    term.scroll_display(Scroll::Delta(lines));
                }
                Input::Exited(code) => {
                    let mut screen = screen.lock().unwrap();
                    screen.exit = Some(code);
                    screen.changed = true;
                }
                Input::Stop => return,
            }
            next = rx.try_recv().ok();
        }

        let events = std::mem::take(&mut *listener.0.borrow_mut());
        for event in events {
            match event {
                Event::PtyWrite(text) => write(text.as_bytes()),
                Event::Title(t) => title = t,
                Event::ResetTitle => title.clear(),
                // only colours the program set itself: the outer terminal's
                // palette, which ideish draws with, is not known here
                Event::ColorRequest(index, format) => {
                    if let Some(rgb) = term.colors()[index] {
                        write(format(rgb).as_bytes());
                    }
                }
                Event::TextAreaSizeRequest(format) => {
                    let reply = format(WindowSize {
                        num_lines: size.rows,
                        num_cols: size.cols,
                        cell_width: CELL_WIDTH,
                        cell_height: CELL_HEIGHT,
                    });
                    write(reply.as_bytes());
                }
                _ => {}
            }
        }

        publish(&mut term, &title, &screen);
    }
}

fn publish(term: &mut Term<Listener>, title: &str, screen: &Mutex<Screen>) {
    let damaged = match term.damage() {
        TermDamage::Full => true,
        TermDamage::Partial(mut lines) => lines.next().is_some(),
    };
    let retitled = screen.lock().unwrap().title != title;
    if !damaged && !retitled {
        return;
    }

    let grid = term.grid();
    let offset = grid.display_offset() as i32;
    let rows = (0..grid.screen_lines() as i32)
        .map(|y| {
            let row = &grid[Line(y - offset)];
            let mut runs = Vec::new();
            for x in 0..grid.columns() {
                push_cell(&mut runs, &row[Column(x)], x as u16);
            }
            runs
        })
        .collect();

    let cursor = term
        .mode()
        .contains(TermMode::SHOW_CURSOR)
        .then(|| term.renderable_content().cursor.point)
        .and_then(|point| {
            let y = point.line.0 + offset;
            (y < grid.screen_lines() as i32).then_some((point.column.0 as u16, y as u16))
        });
    term.reset_damage();

    let mut screen = screen.lock().unwrap();
    screen.rows = rows;
    screen.cursor = cursor;
    screen.title = title.to_string();
    screen.changed = true;
}

fn color(c: Color) -> isize {
    match c {
        Color::Named(name) => {
            let (n, dim) = (name as isize, NamedColor::DimBlack as isize);
            match n {
                0..=15 => n,
                // dim colours fall back to the normal ones
                _ if (dim..dim + 8).contains(&n) => n - dim,
                // foreground, background and cursor: the pane's own
                _ => -1,
            }
        }
        Color::Indexed(index) => index as isize,
        Color::Spec(rgb) => {
            RGB_BASE + ((rgb.r as isize) << 16 | (rgb.g as isize) << 8 | rgb.b as isize)
        }
    }
}

/// Appends the cell at col to the row, extending the last run when the style matches
fn push_cell(runs: &mut Vec<Run>, cell: &Cell, col: u16) {
    // the right half of a wide character: the left half already covers it
    if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
        return;
    }
    let mut flags = 0;
    for (cell_flag, flag) in [
        (Flags::BOLD, BOLD),
        (Flags::ITALIC, ITALIC),
        (Flags::DIM, FAINT),
        (Flags::ALL_UNDERLINES, UNDERLINE),
        (Flags::INVERSE, INVERSE),
        (Flags::STRIKEOUT, STRIKETHROUGH),
    ] {
        if cell.flags.intersects(cell_flag) {
            flags |= flag;
        }
    }
    let (fg, bg) = (color(cell.fg), color(cell.bg));

    let wide = cell.flags.contains(Flags::WIDE_CHAR);
    let text: String = if cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER) {
        // a wide character that did not fit at the end of the line
        " ".to_string()
    } else if cell.flags.contains(Flags::HIDDEN) {
        if wide { "  " } else { " " }.to_string()
    } else {
        std::iter::once(cell.c)
            .chain(cell.zerowidth().into_iter().flatten().copied())
            .collect()
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

/// ESC is dropped so the text cannot end a bracketed paste early
fn encode_paste(text: &str, bracketed: bool) -> Vec<u8> {
    let text = text.replace('\x1b', "");
    if bracketed {
        format!("\x1b[200~{text}\x1b[201~").into_bytes()
    } else {
        text.replace("\r\n", "\r").replace('\n', "\r").into_bytes()
    }
}
