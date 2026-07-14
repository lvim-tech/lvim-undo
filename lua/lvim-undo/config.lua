-- lvim-undo.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (via lvim-utils.utils.merge),
-- so every require("lvim-undo.config") reader sees the effective values. NOTHING visual or
-- behavioural is hardcoded anywhere else in the plugin: every glyph, title, label, accent, tint,
-- key, dimension and timing the panel uses lives here. Colour entries name a PALETTE key (they
-- track the live lvim-colorscheme theme) and a TINT ROLE from the shared lvim-utils.config.ui
-- scale (`"strong"`, `"badge"`, …) — a raw number is also accepted; the plugin never invents a
-- parallel tint scale.
--
---@module "lvim-undo.config"

---@class LvimUndoDiffNative
---@field result_type "unified"|"indices"  vim.text.diff output: unified text, or hunk index summaries
---@field ctxlen integer                   context lines around each hunk (unified)
---@field algorithm "myers"|"minimal"|"patience"|"histogram"  the diff algorithm

---@class LvimUndoDiff
---@field engine "native"|"delta"|"difft"|"diff"  which engine renders the preview
---@field preview_on_move boolean         the diff follows the timeline cursor (scrub the history)
---@field debounce integer                milliseconds the cursor-follow diff is debounced
---@field native LvimUndoDiffNative       knobs for the built-in vim.text.diff engine
---@field external table<string, string[]>  per-tool argv (the two state files are appended)
---@field embed table<string, string[]>   per-tool argv that makes it render INTO our terminal (see below)
---@field background table<string, table<string, string>>  per-tool flag for &background (dark/light)

---@class LvimUndoPersist
---@field tags boolean                    persist tags/checkpoints in the sqlite store; false = session-only
---@field max_file_size integer|false     above this many bytes a buffer gets no persistent undo (false = off)
---@field exclude_filetypes string[]      filetypes that never get persistent undo (chrome is excluded by construction)

---@class LvimUndoCheckpointsAuto
---@field format boolean                  named checkpoint before vim.lsp.buf.format
---@field lsp_rename boolean              named checkpoint before vim.lsp.buf.rename
---@field build boolean                   named checkpoint on the `build_event` User autocmd

---@class LvimUndoCheckpoints
---@field auto LvimUndoCheckpointsAuto    opt-in automatic checkpoints
---@field labels table<string, string>    the checkpoint name each auto trigger records
---@field build_event string              User autocmd pattern the `build` trigger listens on

---@class LvimUndoSearch
---@field max_states integer              content search walks at most this many (newest) states

---@class LvimUndoProject
---@field limit integer                   rows shown in the project checkpoints view

---@class LvimUndoColor
---@field accent string                   a lvim-utils palette key ("blue", …) or a literal "#rrggbb"
---@field tint string|number|nil          a tint ROLE name from lvim-utils.config.ui (`tint.<role>`) or a raw factor

---@class LvimUndoColors
---@field current LvimUndoColor           the current state's row marker
---@field state LvimUndoColor             a state's sequence number
---@field time LvimUndoColor              the age cell
---@field saved LvimUndoColor             the saved-state icon
---@field tag LvimUndoColor               a tag badge box
---@field checkpoint LvimUndoColor        a named-checkpoint badge box
---@field file LvimUndoColor              a project row's file name
---@field added LvimUndoColor             native diff: added lines
---@field removed LvimUndoColor           native diff: removed lines
---@field hunk LvimUndoColor              native diff: @@ hunk headers
---@field context LvimUndoColor           native diff: context lines
---@field empty LvimUndoColor             placeholders
---@field filter LvimUndoColor            the panel header band

---@class LvimUndoConfig
---@field layout "float"|"area"|"bottom"  how the panel opens (the layout canon)
---@field width number                    the timeline pane's share of the frame; the diff preview takes the rest
---@field preview_side "right"|"left"|"above"|"below"  where the diff preview sits relative to the timeline
---@field time_format "relative"|"pretty"|"absolute"  how a state's age renders
---@field absolute_format string          os.date() format used by time_format = "absolute"
---@field view "all"|"current"            the initial timeline view (whole tree / current timeline only)
---@field filetype string                 stamped on the timeline panel buffer
---@field diff LvimUndoDiff
---@field persist LvimUndoPersist
---@field checkpoints LvimUndoCheckpoints
---@field search LvimUndoSearch
---@field project LvimUndoProject
---@field keys table<string, string>      panel keys (vim notation)
---@field titles table<string, string>    every window/prompt title the plugin shows
---@field labels table<string, string>    footer chips, placeholders and header words
---@field icons table<string, string>     every glyph (Nerd Font, single-width; pointer/separator = ➤)
---@field colors LvimUndoColors           accents + tint roles per component

---@type LvimUndoConfig
return {
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
        -- How a tool must be invoked to render INTO our preview terminal — a mechanism, not a taste.
        -- We hand the engine a PTY (that is the only way to get its colours), so it also believes it is
        -- an interactive terminal session, and two things follow:
        --   `--paging=never` — else delta pipes itself through `$PAGER`, and a Neovim-based pager
        --     (nvimpager) lands a whole nested editor — and its modeline errors — inside the preview.
        --   `--dark`/`--light` — else delta ASKS the terminal for its background colour (OSC 11) and
        --     waits out a ~1s timeout, since our PTY has nobody to answer. Measured: 1068ms → 68ms.
        embed = {
            delta = { "--paging=never" },
        },
        -- Per-engine flag for `&background`, appended to `embed` (see above).
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
        help = "g?", -- the set-wide cheatsheet chord (the panel owns the `g` prefix — see lvim-ui)
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
        help = "help",
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
    },
}
