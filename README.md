# ideish.hx

A UI layer for [Steel-enabled Helix](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md): a file tree, a bufferline, a breadcrumb bar, a statusline and an agent pane on one layout.

## Parts

| Part | Where | What |
| --- | --- | --- |
| Tree | left or right pane | Files with icons and git status, follows the disk without polling, create / rename / delete |
| Bufferline | top bar | One tab per buffer, clickable, scrolls around the focused tab when they do not fit |
| Breadcrumb | top bar, below the tabs | The file's path and the scopes around the cursor (function, class, heading, ...), read from the syntax tree |
| Statusline | bottom bar | Mode, file, agent state, git branch, diagnostics, selections, language servers, file type, position |
| Agent | right pane | A conversation with an [ACP](https://agentclientprotocol.com) agent: streaming replies, tool calls with diffs, permission prompts, interrupt, modes |

The breadcrumb knows Rust, Python, Go, JavaScript and TypeScript, C and C++, Java, C#, Ruby, Lua, Bash, Zig, Scheme, Markdown, TOML, JSON and YAML; other languages show the path only.

Buffers changed on disk are reloaded when they have no unsaved edits.

## Requirements

- Steel-enabled Helix (`steel-event-system` branch) and `forge`
- A Rust toolchain (forge builds the native library)
- A terminal font with Nerd Fonts 3.3 or later
- For the agent pane: the agent's ACP command on PATH. Only Claude is supported so far:
  `npm install -g @agentclientprotocol/claude-agent-acp`, then log in by running `claude` and `/login`.
  `:ideish-health` shows what is found.

## Installation

```sh
forge pkg install --git https://github.com/wtnbass/ideish.hx.git
```

In `init.scm`, enable the parts you want. The order does not matter:

```scheme
(require "ideish/ideish.scm")
(ideish-bufferline!)
(ideish-breadcrumb!)
(ideish-statusline!)
(ideish-tree! #:side 'left #:width 30)
(ideish-agent!)
```

In `config.toml`:

```toml
[keys.normal.space]
e = ":ideish-focus tree"
E = ":ideish-toggle tree"

[keys.normal.ret]
a = ":ideish-toggle agent"
s = ":ideish-agent-add-selection"
```

### Options

| Call | Options |
| --- | --- |
| `(ideish-tree!)` | `#:side` `'left` / `'right` (default `'left`), `#:width` (30), `#:show-hidden` (`#t`), `#:show-ignored` (`#t`) |
| `(ideish-bufferline!)` | `#:mode` `'multiple` (while two or more buffers are open, default) / `'always` |
| `(ideish-breadcrumb!)` | none |
| `(ideish-statusline!)` | none |
| `(ideish-agent!)` | `#:width` (64), `#:mode` the mode every session starts in (e.g. `"auto"`; without it, the mode last picked with Shift-Tab), `#:command '("program" "arg" ...)` to start something other than the agent found on PATH |
| `(ideish-pill-style! 'slant)` | ends of tabs and the mode label: `'square` (default), `'slant` or `'round` |
| `(ideish-icon-scopes! (hash 'cyan "type.builtin"))` | which theme scope colours each icon colour class |

## Commands

| Command | Action |
| --- | --- |
| `:ideish-focus tree` | Show the tree and give it the keyboard; reveals the current file when the tree opens |
| `:ideish-toggle tree` | Show the tree with focus, or hide it |
| `:ideish-close tree` | Hide the tree |
| `:ideish-tree-reveal` | Focus the tree on the current file |
| `:ideish-toggle agent` | Show the agent pane with focus (starting the agent the first time), or hide it |
| `:ideish-agent-add-selection` / `:ideish-agent-add-file` | Attach the selection or the current file to the next prompt |
| `:ideish-agent-new` / `:ideish-agent-cancel` / `:ideish-agent-stop` | New conversation / interrupt the turn / stop the agent |
| `:ideish-health` | Show which agents are installed |

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
| `.` | Show or hide dotfiles |
| `I` | Show or hide git-ignored entries |
| `f` | Jump to the current file |
| `R` | Re-read every directory |
| `+` / `-` | Wider / narrower |
| `q` | Hide the tree |
| Esc | Back to the editor; the tree stays open |

With the mouse, a click opens a file or toggles a directory, and the wheel scrolls. Clicking a tab switches to that buffer.

Git markers: `M` modified, `A` added, `U` untracked, `D` deleted, `R` renamed, `!` conflict. Ignored entries are dimmed.

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

## Development

```sh
make native   # build libideish into ~/.local/share/steel/native
make test     # unit tests, under the steel CLI
make smoke    # start Helix with dev/init.scm in tmux and check that the parts draw
make icons    # regenerate icons/catalog.scm from nvim-web-devicons
HELIX_STEEL_CONFIG=$PWD/dev hx   # try this checkout without touching your config
```

With the dev config, `IDEISH_AGENT="node dev/fake-agent.mjs"` replaces the agent with a scripted one.

## Credits

File icons come from [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), MIT licensed; see `icons/LICENSE-nvim-web-devicons`.
