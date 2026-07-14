# lvim-undo

A navigable, branching **undo-history timeline** for Neovim, built on the lvim-tech
ecosystem (`lvim-ui` panel chassis, `lvim-utils` palette / store / merge).

Every undo state of the buffer is a row in a foldable graph — walk it, scrub a live
diff of any state against the current one, restore any state (across branches), tag
the states worth remembering, inspect an old state in a scratch buffer or a diffsplit
without touching the live buffer, and list recent checkpoints across the whole
project. The undo tree itself always comes from Neovim (`undotree()`); the plugin
never keeps a shadow copy — only the metadata Neovim has nowhere to put (tags and
named checkpoints, persisted in its own SQLite store).

- **Timeline panel** — the whole undo graph as a tree (branch connectors, folds,
  scrollbar), the current state marked with `➤`, each row carrying its sequence
  number, age, save marker and tag/checkpoint badges. Two views, toggled in-panel:
  the whole tree, or only the timeline plain `u` / `<C-r>` can reach.
- **Live diff preview** — the diff between the state under the cursor and the current
  state follows the cursor (debounced) in a preview pane beside the timeline. Engines:
  Neovim's native `vim.text.diff` (default, no external process, per-line highlights),
  or `delta` / `difft` / `diff` rendered with their real ANSI colours through a PTY
  into a terminal buffer.
- **Tags & named checkpoints** — several tags per state, edited from the panel
  (space-separated, empty clears). A public `checkpoint(name)` API lets any plugin
  stamp "before the rename" onto the current state; opt-in automatic checkpoints
  before `vim.lsp.buf.format`, `vim.lsp.buf.rename` or a build `User` event. Persisted
  in the plugin's own SQLite database (via `lvim-utils.store`), keyed by
  (file, seq, seq-timestamp) so a purged / rewritten undofile can never resurrect
  stale marks. Tags survive restarts and die with a purge.
- **Search / filter** — `/` filters the timeline by tag (`#wip`), by age (`@hour`,
  `@today`) or by **content**: type text and only the states whose own change touches
  it remain ("the version where that function still existed").
- **Scratch restore** — open the selected state read-only in a vsplit (syntax
  highlighted by language, no LSP attach) to look at and yank from it, or as a
  **diffsplit** against the live buffer; diff mode unwinds when the scratch closes.
- **Project view** — a second tab lists the stored tags / checkpoints across every
  file, newest first; activating a row opens its file and restores that state (with a
  staleness guard).
- **Undofile management** — purge this buffer's history or all undofiles (confirm
  dialog; `!` skips it); a persistence filter turns `undofile` off for oversized files
  and excluded filetypes.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-undo/blob/main/LICENSE)

## Requirements

- Neovim **>= 0.12** (`vim.text.diff`, `undotree(buf)`)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — palette, highlight factory, store, merge
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) — the panel chassis (tabs, tree, input, confirm, info)
- Optional: [sqlite.lua](https://github.com/kkharji/sqlite.lua) for persistent tags
  (without it — or with `persist.tags = false` — tags are session-only)
- Optional: `delta` / `difft` / `diff` on `PATH` for the external diff engines

## Installation

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and
install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external
plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-undo" },
})
require("lvim-undo").setup({})
```

## Usage

```vim
:LvimUndo                        " toggle the timeline panel
:LvimUndo open | close           " explicit open / close
:LvimUndo project                " open on the Project (recent checkpoints) tab
:LvimUndo bottom                 " a layout token (float|area|bottom) anywhere in the
                                 " args; a per-command layout is sticky for the session
:LvimUndo purge                  " purge THIS buffer's undo history (confirm; ! skips)
:LvimUndo purge-all              " purge ALL undofiles + every stored mark (confirm; ! skips)
:LvimUndo checkpoint <name>      " record a named checkpoint at the current state
:LvimUndo log                    " the session action log
:LvimUndo log-clear              " clear it
```

### Panel keys (all configurable via `keys`)

| Key     | Action                                                 |
| ------- | ------------------------------------------------------ |
| `<CR>`  | restore the selected state / open a project row        |
| `u`     | undo one step in the real buffer (the panel follows)   |
| `<C-r>` | redo one step                                          |
| `p`     | refresh the diff preview                               |
| `t`     | edit the selected state's tags (empty input clears)    |
| `c`     | toggle whole tree / current timeline                   |
| `/`     | filter: `#tag`, `@hour`, `@today`, content text        |
| `s`     | open the selected state in a read-only scratch vsplit  |
| `S`     | scratch + `:diffthis` against the live buffer          |
| `l`     | expand a collapsed branch                              |
| `h`     | collapse a branch / jump to the fork row               |
| `r`     | refresh the timeline (re-reads marks + the undo tree)  |
| `g?`    | the keymap cheatsheet                                  |
| `q`     | close                                                  |

### API

```lua
local undo = require("lvim-undo")

undo.open({ layout = "float", tab = "timeline" }) -- both optional
undo.close()
undo.toggle()

-- Stamp a NAMED CHECKPOINT on a buffer's current undo state — the seam other plugins
-- call before an operation worth remembering. Returns false on a non-file buffer.
undo.checkpoint("before the refactor", { buf = 0 })

undo.purge(force) -- this buffer's undofile + in-memory tree + stored marks
undo.purge_all(force) -- every undofile + every stored mark
undo.show_log()
undo.clear_log()
```

### Events

`User` autocmds fire on every noteworthy action, so a statusline / dashboard can react:
`LvimUndoCheckpoint`, `LvimUndoRestore`, `LvimUndoStep`, `LvimUndoPurge`,
`LvimUndoTags` — each with a `data` payload (file, seq, …).

## Setup

The full default configuration — every option at its default value:

```lua
require("lvim-undo").setup({
    layout = "float", -- float | area | bottom
    width = 0.4, -- the timeline pane's share of the frame; the preview takes the rest
    preview_side = "right", -- right | left | above | below
    time_format = "relative", -- relative | pretty | absolute
    absolute_format = "%Y-%m-%d %H:%M:%S",
    view = "all", -- all | current  (the initial timeline view)
    filetype = "lvim-undo",

    diff = {
        engine = "native", -- native | delta | difft | diff
        preview_on_move = true, -- scrub the history: the diff follows the cursor
        debounce = 40,
        native = { result_type = "unified", ctxlen = 3, algorithm = "histogram" },
        -- How a tool must be invoked to render INTO the preview rather than into a pager: the engine
        -- runs on a PTY (that is how it emits colour), so it also thinks it may page itself through
        -- $PAGER. Mechanism, not taste — change only if an engine's CLI does.
        embed = {
            delta = { "--paging=never" },
        },
        -- The flag for &background, appended to `embed`: without it delta ASKS the terminal for its
        -- background colour and waits out a ~1s timeout on our PTY (measured 1068ms → 68ms).
        background = {
            delta = { dark = "--dark", light = "--light" },
        },
        external = {
            delta = {
                "--side-by-side",
                "--line-numbers",
                "--navigate",
                "--file-style=omit",
                "--hunk-header-style=omit",
            },
            difft = { "--display=inline" },
            diff = { "-u" },
        },
    },

    persist = {
        tags = true, -- the sqlite store (own db); false = tags are session-only
        max_file_size = 1024 * 1024, -- above this a buffer gets no persistent undo (false = off)
        exclude_filetypes = {}, -- on top of the built-in "chrome is not content" guard
    },

    checkpoints = {
        auto = { format = false, lsp_rename = false, build = false }, -- opt-in named checkpoints
        labels = { format = "before format", lsp_rename = "before rename", build = "before build" },
        build_event = "LvimBuildStart", -- the User autocmd pattern the `build` trigger listens on
    },

    search = {
        max_states = 400, -- content search walks at most this many (newest) states
    },

    project = {
        limit = 100, -- rows in the project checkpoints view
    },

    keys = {
        restore = "<CR>",
        preview = "p",
        tag = "t",
        refresh = "r",
        toggle_view = "c",
        undo = "u",
        redo = "<C-r>",
        search = "/",
        scratch = "s", -- open the selected state in a scratch buffer instead of restoring
        diffsplit = "S", -- scratch + :diffthis against the live buffer
        expand = "l", -- expand a collapsed branch
        collapse = "h", -- collapse a branch / jump to the fork row
        help = "g?",
        close = "q",
    },

    titles = {
        panel = "Undo",
        timeline = "Timeline",
        project = "Project",
        help = "Undo keys",
        tag = "Tags (space-separated, empty clears)",
        search = "Filter (#tag, @hour, @today, text)",
        purge = "Purge this buffer's undo history?",
        purge_all = "Purge ALL undofiles?",
        log = "Undo log",
        scratch = "lvim-undo", -- the scratch buffer name scheme: <scratch>://<file>@<seq>
    },

    labels = {
        restore = "restore",
        tag = "tag",
        view = "view",
        search = "search",
        scratch = "scratch",
        close = "close",
        view_all = "all",
        view_current = "current",
        empty_timeline = "No undo history yet",
        empty_project = "No stored checkpoints yet",
        no_matches = "No states match the filter",
        no_diff = "No changes between the selected and current state",
        no_selection = "Select a state to preview its diff",
        origin = "origin", -- the seq-0 root row
        log_empty = "Nothing logged yet",
    },

    icons = {
        panel = "󰕌", -- the panel / Timeline tab
        project = "󰋚", -- the Project (recent checkpoints) tab
        state = "󰄰", -- an undo state row
        current = "➤", -- the current state (the canonical pointer)
        saved = "󰆓", -- a state the file was written at
        tag = "󰓹", -- a tag badge
        checkpoint = "󰃀", -- a named checkpoint badge
        time = "󰥔", -- the age cell in the project preview
        search = "󰍉", -- the active-filter header cell
        separator = "➤", -- the header breadcrumb separator (the canonical separator)
    },

    colors = {
        -- Each entry: `accent` = a palette key (tracks the live theme) or "#rrggbb";
        -- `tint` = a ROLE from the shared lvim-utils.config.ui tint scale, or a raw factor.
        current = { accent = "blue", tint = "badge" }, -- the current state's row marker
        state = { accent = "yellow" }, -- a state's sequence number
        time = { accent = "comment" }, -- the age cell
        saved = { accent = "green" }, -- the saved-state icon
        tag = { accent = "yellow", tint = "badge" }, -- a tag badge box
        checkpoint = { accent = "orange", tint = "badge" }, -- a checkpoint badge box
        file = { accent = "blue" }, -- a project row's file name
        added = { accent = "green" }, -- native diff: added lines
        removed = { accent = "red" }, -- native diff: removed lines
        hunk = { accent = "blue" }, -- native diff: @@ hunk headers
        context = { accent = "comment" }, -- native diff: context lines
        empty = { accent = "comment" }, -- placeholders
        filter = { accent = "green", tint = "strong" }, -- the panel header (file ➤ view ➤ filter)
        help = { odd = "blue", even = "yellow", key_tint = "bright", desc_tint = "strong" },
    },
})
```

## Persistence

Tags and named checkpoints live in the plugin's **own** SQLite database under
`stdpath("data")/lvim-undo/` (through the shared `lvim-utils.store` wrapper). Each
mark is keyed by `(file, seq, seq_time)` — the undo entry's own timestamp — so a row
whose state no longer exists in the live tree is stale and silently skipped. Purging
a buffer (or everything) drops the matching marks together with the undofiles. With
`persist.tags = false`, or without sqlite.lua, the same API runs over an in-memory
table and tags become session-only.

## Highlights

Every group is built from the live lvim-utils palette and the `colors` roles above,
registered through the shared highlight factory, and re-derives on `ColorScheme`:
`LvimUndoCurrent`, `LvimUndoSeq`, `LvimUndoTime`, `LvimUndoSaved`, `LvimUndoTagBadge`,
`LvimUndoCheckpointBadge`, `LvimUndoFile`, `LvimUndoEmpty`, `LvimUndoHeader`,
`LvimUndoAdded`, `LvimUndoRemoved`, `LvimUndoHunk`, `LvimUndoContext`, and the
`LvimUndoHelp*` cheatsheet groups.

## Health

```vim
:checkhealth lvim-undo
```

Reports whether `undofile` is on and `undodir` writable, which external diff engines
are on `PATH`, how large the undodir has grown, which persistence backend the tag
store opened, and the persistence-filter verdict for the current buffer ("why is
nothing being remembered here?").

## License

BSD 3-Clause — see [LICENSE](LICENSE).
