# ideish.hx

A UI layer for [Steel-enabled Helix](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md): a file tree, a diff view, a bufferline, a breadcrumb bar, a statusline, an agent pane and a terminal on one layout.

## Parts

| Part | Where | What |
| --- | --- | --- |
| Tree | left or right pane | Files with icons and git status, follows the disk without polling, create / rename / delete. In changes mode, the files git reports as changed |
| Diff | over the editor | A file against HEAD, in the language's syntax colours with added and deleted rows tinted. Follows the file as it changes |
| Bufferline | top bar | One tab per buffer, clickable, scrolls around the focused tab when they do not fit |
| Breadcrumb | top bar, below the tabs | The file's path and the scopes around the cursor (function, class, heading, ...), read from the syntax tree |
| Statusline | bottom bar | Mode, file, agent state, git branch, diagnostics, selections, language servers, file type, position |
| Agent | right pane | A conversation with an [ACP](https://agentclientprotocol.com) agent: streaming replies, tool calls with diffs, permission prompts, interrupt, modes |
| Terminal | bottom pane, below the statusline and the message row | A shell emulated by [libghostty-vt](https://github.com/uzaaft/libghostty-rs): colours from your terminal's palette, full-screen programs, scrollback. Optional, see below |

The breadcrumb knows Rust, Python, Go, JavaScript and TypeScript, C and C++, Java, C#, Ruby, Lua, Bash, Zig, Scheme, Markdown, TOML, JSON and YAML; other languages show the path only.

Buffers changed on disk are reloaded when they have no unsaved edits.

## Requirements

- Steel-enabled Helix (`steel-event-system` branch) and `forge`
- A Rust toolchain (forge builds the native library)
- A terminal font with Nerd Fonts 3.3 or later
- For the agent pane: the agent's ACP command on PATH. Only Claude is supported so far:
  `npm install -g @agentclientprotocol/claude-agent-acp`, then log in by running `claude` and `/login`.
  `:ideish-health` shows what is found.
- For the terminal pane: Zig 0.16, to build libghostty-vt. `mise install` in this checkout installs the pinned version
  (Zig 0.15 cannot link on macOS 26).

## Installation

```sh
forge pkg install --git https://github.com/wtnbass/ideish.hx.git
```

The terminal pane is left out of that build, so it needs no Zig. To include it, pass a cfg (forge cannot pass cargo features):

```sh
RUSTFLAGS="--cfg ideish_terminal" ZIG="$(mise which zig)" forge pkg install --git https://github.com/wtnbass/ideish.hx.git
```

`RUSTFLAGS` replaces any `build.rustflags` in your cargo config for this build. Without the cfg, `(ideish-terminal!)` still loads and `:ideish-health` says how to rebuild.

In `init.scm`, enable the parts you want. The order does not matter:

```scheme
(require "ideish/ideish.scm")
(ideish-bufferline!)
(ideish-breadcrumb!)
(ideish-statusline!)
(ideish-tree! #:side 'left #:width 30)
(ideish-agent!)
(ideish-terminal!)
```

In `config.toml`:

```toml
[keys.normal.space]
e = ":ideish-focus tree"
E = ":ideish-toggle tree"

[keys.normal.ret]
a = ":ideish-toggle agent"
s = ":ideish-agent-add-selection"
t = ":ideish-toggle terminal"
```

### Options

| Call | Options |
| --- | --- |
| `(ideish-tree!)` | `#:side` `'left` / `'right` (default `'left`), `#:width` (30), `#:show-hidden` (`#t`), `#:show-ignored` (`#t`) |
| `(ideish-bufferline!)` | `#:mode` `'multiple` (while two or more buffers are open, default) / `'always` |
| `(ideish-breadcrumb!)` | none |
| `(ideish-statusline!)` | none |
| `(ideish-agent!)` | `#:width` (64), `#:mode` the mode every session starts in (e.g. `"auto"`; without it, the mode last picked with Shift-Tab), `#:command '("program" "arg" ...)` to start something other than the agent found on PATH |
| `(ideish-terminal!)` | `#:height` rows (12), `#:command '("program" "arg" ...)` to start something other than `$SHELL` |
| `(ideish-pill-style! 'slant)` | ends of tabs and the mode label: `'square` (default), `'slant` or `'round` |
| `(ideish-icon-scopes! (hash 'cyan "type.builtin"))` | which theme scope colours each icon colour class |

## Commands

| Command | Action |
| --- | --- |
| `:ideish-focus tree` | Show the tree and give it the keyboard; reveals the current file when the tree opens |
| `:ideish-toggle tree` | Show the tree with focus, or hide it |
| `:ideish-close tree` | Hide the tree |
| `:ideish-tree-reveal` | Focus the tree on the current file |
| `:ideish-changes` | Focus the tree in changes mode |
| `:ideish-diff` | Show the current file's diff against HEAD |
| `:ideish-toggle agent` | Show the agent pane with focus (starting the agent the first time), or hide it |
| `:ideish-agent-add-selection` / `:ideish-agent-add-file` | Attach the selection or the current file to the next prompt |
| `:ideish-agent-new` / `:ideish-agent-cancel` / `:ideish-agent-stop` | New conversation / interrupt the turn / stop the agent |
| `:ideish-toggle terminal` | Show the terminal with focus (starting the shell the first time), or hide it. The shell keeps running while hidden |
| `:ideish-health` | Show which agents are installed and whether the terminal is built |

## Keys in the tree

| Key | Action |
| --- | --- |
| `j` / `k`, ↓ / ↑ | Move |
| `Ctrl-d` / `Ctrl-u` | Move half a page |
| `g` / `G`, Home / End | First / last entry |
| `l`, → | Open a directory, step into an open one, preview a file |
| `h`, ← | Close a directory, otherwise go to the parent |
| Enter, `o` | Open the file (focus returns to the editor), or toggle the directory |
| `v` / `s` | Open in a vertical / horizontal split |
| `a` | New file in the selected directory; end the name with `/` for a folder |
| `r` | Rename or move, relative to the entry's directory |
| `d` | Delete; asks for `y` first |
| `c` | Switch between the files and the changes |
| `.` | Show or hide dotfiles |
| `I` | Show or hide git-ignored entries |
| `f` | Jump to the current file |
| `R` | Re-read every directory |
| `+` / `-` | Wider / narrower |
| `q` | Hide the tree |
| Esc | Back to the editor; the tree stays open |

With the mouse, a click opens a file or toggles a directory, and the wheel scrolls. Clicking a tab switches to that buffer.

Git markers: `M` modified, `A` added, `U` untracked, `D` deleted, `R` renamed, `!` conflict. Ignored entries are dimmed.

In changes mode the tree lists the changed files by path. Enter or a click shows a file's diff with focus, `l` shows it and keeps the keys in the tree, and while a diff is on screen it follows the cursor. `o`, `v` and `s` open the file itself; `a`, `r` and `d` do nothing.

## Keys in the diff view

| Key | Action |
| --- | --- |
| `j` / `k`, ↓ / ↑ | Move |
| `Ctrl-d` / `Ctrl-u` | Move half a page |
| `g` / `G`, Home / End | First / last row |
| `n` / `N`, `]` / `[` | Next / previous hunk |
| Enter, `o` | Open the file at the row's line |
| `q`, Esc | Close the diff; back to the tree when it is open |

The diff compares HEAD with the file on disk, so unsaved edits are not in it. The view closes when the editor gets the keys back, since it covers the editor. Syntax colours come from the language's `highlights.scm` in Helix's runtime directory. `locals.scm` is not read, so a parameter is coloured as a parameter only where it is declared.

## Keys in the agent pane

| Key | Action |
| --- | --- |
| Enter | Send |
| Alt-Enter / Ctrl-j | Newline |
| Shift-Tab | Next mode (Manual, Accept edits, Plan, Auto; full-access modes are skipped). The choice is remembered for the next session |
| Ctrl-c | Interrupt the turn, or clear the input |
| Ctrl-n | New conversation |
| Ctrl-t | Show every tool output in full |
| Ctrl-f | Follow the files the agent reads and edits (on by default) |
| ↑ / ↓ | Input history |
| PageUp / PageDown, wheel | Scroll |
| Esc | Back to the editor; the pane stays |

While a permission request is pending: ↑ ↓ or `j` `k` to choose, a number to pick directly, Enter to confirm, Esc to reject. Clicking a tool call opens the file it touched; clicking its header toggles its full output.

## Keys in the terminal

Every key goes to the shell, Esc included. `Ctrl-\` gives the keyboard back to the editor; the pane stays open. A click in the pane focuses it, and the wheel scrolls back through its history. When the shell exits, the pane closes and the next `:ideish-toggle terminal` starts a new one.

## Development

```sh
mise run install  # install this checkout with forge (cog and libideish); --terminal adds the terminal
mise run test     # unit tests, under the steel CLI
mise run smoke    # start Helix with dev/init.scm in tmux and check that the parts draw
mise run icons    # regenerate icons/catalog.scm from nvim-web-devicons
HELIX_STEEL_CONFIG=$PWD/dev hx   # try this checkout without touching your config
```

With the dev config, `IDEISH_AGENT="node dev/fake-agent.mjs"` replaces the agent with a scripted one. `mise run smoke` skips the terminal checks when libideish was built without it. `STEEL_HOME=<dir> mise run smoke` runs against the libideish in `<dir>/native`, for example a build you do not want to put under the running Helix.

## Credits

File icons come from [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), MIT licensed; see `icons/LICENSE-nvim-web-devicons`.
