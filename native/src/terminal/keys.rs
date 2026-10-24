//! Key encoder: the bytes a program expects for a key, given the modes it set.
//!
//! alacritty_terminal records the modes but leaves the encoding to its GUI, so
//! it is done here. This touches neither the emulator nor its thread.
//!
//! Without kitty keyboard flags the keys go out the way xterm sends them;
//! super is dropped there. With any flag, keys are sent as the kitty keyboard
//! protocol describes, for presses only: Helix reports nothing else.

use alacritty_terminal::term::TermMode;

/// Helix's modifier bits
const SHIFT: u8 = 1;
const CTRL: u8 = 2;
const ALT: u8 = 4;
const SUPER: u8 = 8;

const ESC: u8 = 0x1b;

#[derive(Clone, Copy)]
enum Key {
    Char(char),
    Enter,
    Tab,
    Backspace,
    Escape,
    /// Arrows, Home and End: CSI or SS3 with this final byte
    Cursor(char),
    /// F1-F4: SS3 with this final byte
    Function(char),
    /// Insert, Delete, PageUp, PageDown and F5-F12: CSI n ~
    Tilde(u8),
    /// F13-F24, which only the kitty protocol can send: their kitty code
    KittyOnly(u32),
}

impl Key {
    /// name: one of the names ui/terminal.scm sends, or one character
    fn parse(name: &str) -> Option<Key> {
        let mut chars = name.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            return Some(Key::Char(c));
        }
        Some(match name {
            "enter" => Key::Enter,
            "tab" => Key::Tab,
            "backspace" => Key::Backspace,
            "escape" => Key::Escape,
            "up" => Key::Cursor('A'),
            "down" => Key::Cursor('B'),
            "right" => Key::Cursor('C'),
            "left" => Key::Cursor('D'),
            "home" => Key::Cursor('H'),
            "end" => Key::Cursor('F'),
            "insert" => Key::Tilde(2),
            "delete" => Key::Tilde(3),
            "page-up" => Key::Tilde(5),
            "page-down" => Key::Tilde(6),
            _ => {
                const TILDE: [u8; 8] = [15, 17, 18, 19, 20, 21, 23, 24];
                let n: u8 = name.strip_prefix('f')?.parse().ok()?;
                match n {
                    1..=4 => Key::Function(char::from(b'P' + n - 1)),
                    5..=12 => Key::Tilde(TILDE[usize::from(n - 5)]),
                    13..=24 => Key::KittyOnly(57376 + u32::from(n - 13)),
                    _ => return None,
                }
            }
        })
    }
}

/// US-layout pairs of an unshifted character and what shift makes of it
const SHIFTED: [(char, char); 21] = [
    ('1', '!'),
    ('2', '@'),
    ('3', '#'),
    ('4', '$'),
    ('5', '%'),
    ('6', '^'),
    ('7', '&'),
    ('8', '*'),
    ('9', '('),
    ('0', ')'),
    ('-', '_'),
    ('=', '+'),
    ('[', '{'),
    (']', '}'),
    ('\\', '|'),
    (';', ':'),
    ('\'', '"'),
    ('`', '~'),
    (',', '<'),
    ('.', '>'),
    ('/', '?'),
];

/// The character on the same key without shift
fn unshifted(c: char) -> char {
    if c.is_ascii_uppercase() {
        return c.to_ascii_lowercase();
    }
    SHIFTED
        .iter()
        .find(|(_, shifted)| *shifted == c)
        .map_or(c, |(base, _)| *base)
}

#[derive(Clone, Copy)]
struct Mods {
    shift: bool,
    ctrl: bool,
    alt: bool,
    sup: bool,
}

impl Mods {
    /// The modifier parameter m of CSI 1;m A and CSI code;m u
    fn param(self, with_super: bool) -> u32 {
        1 + u32::from(self.shift)
            + u32::from(self.alt) * 2
            + u32::from(self.ctrl) * 4
            + u32::from(self.sup && with_super) * 8
    }
}

/// key: a name from ui/terminal.scm or one character. mods: Helix's bits
/// (1 shift, 2 ctrl, 4 alt, 8 super). text: what the key types, if anything.
/// Empty for a key that cannot be sent.
pub(super) fn encode(key: &str, mods: u8, text: Option<&str>, mode: TermMode) -> Vec<u8> {
    let Some(key) = Key::parse(key) else { return Vec::new() };
    let mods = Mods {
        // Helix may hand over "A" without shift: the character says it was held
        shift: mods & SHIFT != 0 || matches!(key, Key::Char(c) if unshifted(c) != c),
        ctrl: mods & CTRL != 0,
        alt: mods & ALT != 0,
        sup: mods & SUPER != 0,
    };
    if mode.intersects(TermMode::KITTY_KEYBOARD_PROTOCOL) {
        kitty(key, mods, text, mode)
    } else {
        legacy(key, mods, text, mode)
    }
}

/// The control character ctrl makes of c, if any
fn control(c: char) -> Option<u8> {
    match c.to_ascii_lowercase() {
        c @ 'a'..='z' => Some(c as u8 - b'a' + 1),
        '@' | ' ' => Some(0),
        c @ ('[' | '\\' | ']' | '^' | '_') => Some(c as u8 - b'[' + ESC),
        _ => None,
    }
}

fn legacy(key: Key, mods: Mods, text: Option<&str>, mode: TermMode) -> Vec<u8> {
    let alt = |bytes: &[u8]| {
        let mut out = Vec::with_capacity(bytes.len() + 1);
        if mods.alt {
            out.push(ESC);
        }
        out.extend_from_slice(bytes);
        out
    };
    match key {
        Key::Char(c) => match control(c).filter(|_| mods.ctrl) {
            Some(byte) => alt(&[byte]),
            None => alt(typed(c, text).as_bytes()),
        },
        Key::Enter => alt(b"\r"),
        Key::Tab if mods.shift => b"\x1b[Z".to_vec(),
        Key::Tab => b"\t".to_vec(),
        Key::Backspace => alt(if mods.ctrl { b"\x08" } else { b"\x7f" }),
        Key::Escape => alt(&[ESC]),
        Key::KittyOnly(_) => Vec::new(),
        _ => special(key, mods.param(false), mode),
    }
}

fn typed(c: char, text: Option<&str>) -> String {
    text.map_or_else(|| c.to_string(), str::to_string)
}

/// Arrows, Home, End, Insert, Delete, PageUp, PageDown and F1-F12, which
/// keep xterm's form under the kitty protocol too
fn special(key: Key, m: u32, mode: TermMode) -> Vec<u8> {
    let seq = match key {
        Key::Cursor(f) if m == 1 && mode.contains(TermMode::APP_CURSOR) => format!("\x1bO{f}"),
        Key::Cursor(f) if m == 1 => format!("\x1b[{f}"),
        Key::Function(f) if m == 1 => format!("\x1bO{f}"),
        Key::Cursor(f) | Key::Function(f) => format!("\x1b[1;{m}{f}"),
        Key::Tilde(n) if m == 1 => format!("\x1b[{n}~"),
        Key::Tilde(n) => format!("\x1b[{n};{m}~"),
        _ => return Vec::new(),
    };
    seq.into_bytes()
}

fn kitty(key: Key, mods: Mods, text: Option<&str>, mode: TermMode) -> Vec<u8> {
    let all = mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC);
    let m = mods.param(true);
    let code = match key {
        Key::Char(c) => {
            if !all && !(mods.ctrl || mods.alt || mods.sup) {
                return typed(c, text).into_bytes();
            }
            unshifted(c) as u32
        }
        Key::Enter | Key::Tab | Key::Backspace if !all && m == 1 => {
            return legacy(key, mods, text, mode);
        }
        Key::Enter => 13,
        Key::Tab => 9,
        Key::Backspace => 127,
        Key::Escape => 27,
        Key::KittyOnly(code) => code,
        _ => return special(key, m, mode),
    };

    let mut seq = format!("\x1b[{code}");
    if let Key::Char(c) = key {
        if mode.contains(TermMode::REPORT_ALTERNATE_KEYS) && mods.shift && c as u32 != code {
            seq.push_str(&format!(":{}", c as u32));
        }
    }
    // the text a control character stands for is not text
    let associated = text.filter(|t| {
        all && mode.contains(TermMode::REPORT_ASSOCIATED_TEXT)
            && matches!(key, Key::Char(_))
            && !mods.ctrl
            && !t.is_empty()
            && !t.chars().any(char::is_control)
    });
    if m != 1 || associated.is_some() {
        seq.push_str(&format!(";{m}"));
    }
    if let Some(text) = associated {
        let points: Vec<String> = text.chars().map(|c| (c as u32).to_string()).collect();
        seq.push(';');
        seq.push_str(&points.join(":"));
    }
    seq.push('u');
    seq.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: TermMode = TermMode::empty();

    fn key(name: &str, mods: u8, mode: TermMode) -> Vec<u8> {
        let text = (name.chars().count() == 1).then_some(name);
        encode(name, mods, text, mode)
    }

    fn assert_key(name: &str, mods: u8, mode: TermMode, expected: &[u8]) {
        assert_eq!(
            key(name, mods, mode),
            expected,
            "{name:?} mods {mods} mode {mode:?}: got {:?}",
            String::from_utf8_lossy(&key(name, mods, mode))
        );
    }

    #[test]
    fn legacy_characters() {
        assert_key("a", 0, NONE, b"a");
        assert_key("A", SHIFT, NONE, b"A");
        assert_key("A", 0, NONE, b"A");
        assert_key("あ", 0, NONE, "あ".as_bytes());
        assert_key("a", CTRL, NONE, b"\x01");
        assert_key("z", CTRL, NONE, b"\x1a");
        assert_key("A", CTRL | SHIFT, NONE, b"\x01");
        assert_key("@", CTRL, NONE, b"\x00");
        assert_key(" ", CTRL, NONE, b"\x00");
        assert_key("[", CTRL, NONE, b"\x1b");
        assert_key("\\", CTRL, NONE, b"\x1c");
        assert_key("]", CTRL, NONE, b"\x1d");
        assert_key("^", CTRL, NONE, b"\x1e");
        assert_key("_", CTRL, NONE, b"\x1f");
        assert_key("1", CTRL, NONE, b"1");
        assert_key("a", ALT, NONE, b"\x1ba");
        assert_key("a", CTRL | ALT, NONE, b"\x1b\x01");
        assert_key("a", SUPER, NONE, b"a");
    }

    #[test]
    fn legacy_named_keys() {
        assert_key("enter", 0, NONE, b"\r");
        assert_key("enter", ALT, NONE, b"\x1b\r");
        assert_key("tab", 0, NONE, b"\t");
        assert_key("tab", SHIFT, NONE, b"\x1b[Z");
        assert_key("backspace", 0, NONE, b"\x7f");
        assert_key("backspace", CTRL, NONE, b"\x08");
        assert_key("backspace", ALT, NONE, b"\x1b\x7f");
        assert_key("escape", 0, NONE, b"\x1b");
        assert_key("escape", ALT, NONE, b"\x1b\x1b");
    }

    #[test]
    fn legacy_cursor_keys() {
        assert_key("up", 0, NONE, b"\x1b[A");
        assert_key("down", 0, NONE, b"\x1b[B");
        assert_key("right", 0, NONE, b"\x1b[C");
        assert_key("left", 0, NONE, b"\x1b[D");
        assert_key("home", 0, NONE, b"\x1b[H");
        assert_key("end", 0, NONE, b"\x1b[F");
        assert_key("up", 0, TermMode::APP_CURSOR, b"\x1bOA");
        assert_key("home", 0, TermMode::APP_CURSOR, b"\x1bOH");
        assert_key("up", SHIFT, NONE, b"\x1b[1;2A");
        assert_key("left", CTRL, TermMode::APP_CURSOR, b"\x1b[1;5D");
        assert_key("right", ALT | CTRL, NONE, b"\x1b[1;7C");
        assert_key("up", SUPER, NONE, b"\x1b[A");
    }

    #[test]
    fn legacy_tilde_and_function_keys() {
        assert_key("insert", 0, NONE, b"\x1b[2~");
        assert_key("delete", 0, NONE, b"\x1b[3~");
        assert_key("page-up", 0, NONE, b"\x1b[5~");
        assert_key("page-down", 0, NONE, b"\x1b[6~");
        assert_key("delete", CTRL, NONE, b"\x1b[3;5~");
        assert_key("f1", 0, NONE, b"\x1bOP");
        assert_key("f4", 0, NONE, b"\x1bOS");
        assert_key("f2", SHIFT, NONE, b"\x1b[1;2Q");
        assert_key("f5", 0, NONE, b"\x1b[15~");
        assert_key("f6", 0, NONE, b"\x1b[17~");
        assert_key("f10", 0, NONE, b"\x1b[21~");
        assert_key("f11", 0, NONE, b"\x1b[23~");
        assert_key("f12", ALT, NONE, b"\x1b[24;3~");
        assert_key("f13", 0, NONE, b"");
        assert_key("f24", 0, NONE, b"");
    }

    #[test]
    fn unknown_keys() {
        assert_key("f25", 0, NONE, b"");
        assert_key("f0", 0, NONE, b"");
        assert_key("caps-lock", 0, NONE, b"");
        assert_key("", 0, NONE, b"");
    }

    const DISAMBIGUATE: TermMode = TermMode::DISAMBIGUATE_ESC_CODES;

    #[test]
    fn kitty_disambiguate() {
        // Ctrl+I and Tab stay apart
        assert_key("i", CTRL, DISAMBIGUATE, b"\x1b[105;5u");
        assert_key("tab", 0, DISAMBIGUATE, b"\t");
        assert_key("a", 0, DISAMBIGUATE, b"a");
        assert_key("A", SHIFT, DISAMBIGUATE, b"A");
        assert_key("A", CTRL | SHIFT, DISAMBIGUATE, b"\x1b[97;6u");
        assert_key("a", ALT, DISAMBIGUATE, b"\x1b[97;3u");
        assert_key("a", SUPER, DISAMBIGUATE, b"\x1b[97;9u");
        assert_key("escape", 0, DISAMBIGUATE, b"\x1b[27u");
        assert_key("escape", SHIFT, DISAMBIGUATE, b"\x1b[27;2u");
        assert_key("enter", 0, DISAMBIGUATE, b"\r");
        assert_key("enter", SHIFT, DISAMBIGUATE, b"\x1b[13;2u");
        assert_key("tab", SHIFT, DISAMBIGUATE, b"\x1b[9;2u");
        assert_key("backspace", CTRL, DISAMBIGUATE, b"\x1b[127;5u");
        assert_key("backspace", 0, DISAMBIGUATE, b"\x7f");
    }

    #[test]
    fn kitty_keeps_the_legacy_form_of_special_keys() {
        assert_key("up", 0, DISAMBIGUATE, b"\x1b[A");
        assert_key("up", 0, DISAMBIGUATE | TermMode::APP_CURSOR, b"\x1bOA");
        assert_key("up", CTRL, DISAMBIGUATE, b"\x1b[1;5A");
        assert_key("up", SUPER, DISAMBIGUATE, b"\x1b[1;9A");
        assert_key("page-down", SHIFT, DISAMBIGUATE, b"\x1b[6;2~");
        assert_key("f1", 0, DISAMBIGUATE, b"\x1bOP");
        assert_key("f5", CTRL, DISAMBIGUATE, b"\x1b[15;5~");
        assert_key("f13", 0, DISAMBIGUATE, b"\x1b[57376u");
        assert_key("f24", SHIFT, DISAMBIGUATE, b"\x1b[57387;2u");
    }

    const ALL: TermMode = TermMode::DISAMBIGUATE_ESC_CODES.union(TermMode::REPORT_ALL_KEYS_AS_ESC);

    #[test]
    fn kitty_report_all_keys() {
        assert_key("a", 0, ALL, b"\x1b[97u");
        assert_key("A", SHIFT, ALL, b"\x1b[97;2u");
        assert_key("!", 0, ALL, b"\x1b[49;2u");
        assert_key("enter", 0, ALL, b"\x1b[13u");
        assert_key("tab", 0, ALL, b"\x1b[9u");
        assert_key("backspace", 0, ALL, b"\x1b[127u");
        assert_key("escape", 0, ALL, b"\x1b[27u");
        assert_key("up", 0, ALL, b"\x1b[A");
    }

    #[test]
    fn kitty_alternate_keys() {
        let mode = DISAMBIGUATE | TermMode::REPORT_ALTERNATE_KEYS;
        assert_key("A", CTRL | SHIFT, mode, b"\x1b[97:65;6u");
        assert_key("a", CTRL, mode, b"\x1b[97;5u");
        assert_key("A", SHIFT, mode, b"A");
        assert_key("A", SHIFT, ALL | TermMode::REPORT_ALTERNATE_KEYS, b"\x1b[97:65;2u");
        assert_key("{", SHIFT, ALL | TermMode::REPORT_ALTERNATE_KEYS, b"\x1b[91:123;2u");
    }

    #[test]
    fn kitty_associated_text() {
        let mode = ALL | TermMode::REPORT_ASSOCIATED_TEXT;
        assert_key("a", 0, mode, b"\x1b[97;1;97u");
        assert_key("A", SHIFT, mode, b"\x1b[97;2;65u");
        assert_key("a", CTRL, mode, b"\x1b[97;5u");
        assert_key("enter", 0, mode, b"\x1b[13u");
        // without report-all, text goes out as itself
        assert_key("a", 0, DISAMBIGUATE | TermMode::REPORT_ASSOCIATED_TEXT, b"a");
    }

    #[test]
    fn kitty_event_types_add_nothing() {
        let mode = DISAMBIGUATE | TermMode::REPORT_EVENT_TYPES;
        assert_key("i", CTRL, mode, b"\x1b[105;5u");
        assert_key("escape", 0, mode, b"\x1b[27u");
    }
}
