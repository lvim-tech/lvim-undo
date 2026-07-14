-- lvim-undo.panel: the timeline UI — one `lvim-ui.tabs` frame in PROVIDER mode, two tabs sharing a
-- single `lvim-ui.tree` (Timeline = the buffer's undo graph, Project = the stored checkpoints
-- across every file), with the diff preview as the chassis preview block beside it. The chassis
-- owns every window, band, sector, layout and the cursor hiding; this module only builds nodes and
-- reacts to keys.
--
-- Why ONE tree for two tabs: provider tabs share one panel window, and the tree primitive wires
-- its keys / mouse / CursorMoved exactly once (the chassis `keys` hook fires for the tab active at
-- open). Two tree handles would leave the second one deaf. One handle whose root FACTORY switches
-- on the active mode keeps every binding live in both tabs for free; fold state cannot clash
-- because node ids are mode-prefixed ("s:<seq>" / "p:<id>").
--
-- The tree shape mirrors `model.snapshot`: the top level is the MAIN chain newest-first (the
-- branch ending at seq_last) with the origin row at the bottom; a state where the history FORKED
-- carries its alternate branches as children (newest branch first, each newest-first), so a fold
-- collapses a whole abandoned line. The "current" view flattens to exactly the states plain
-- `u`/`<C-r>` can reach; an active filter flattens to the matching states.
--
---@module "lvim-undo.panel"

local config = require("lvim-undo.config")
local model = require("lvim-undo.model")
local tags = require("lvim-undo.tags")
local store = require("lvim-undo.store")
local diff = require("lvim-undo.diff")
local log = require("lvim-undo.log")
local ui = require("lvim-ui")
local surface = require("lvim-ui.surface")
local uipreview = require("lvim-ui.preview")
local uhl = require("lvim-utils.highlight")
local iconlib = require("lvim-utils.icons")

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

---@class LvimUndoOpenOpts
---@field layout string|nil            per-open layout override ("float" | "area" | "bottom"; session-sticky)
---@field tab string|nil               the initial tab ("timeline" | "project")

---@class LvimUndoFilter
---@field tags string[]         tag/checkpoint name fragments (all must match)
---@field age "hour"|"today"|nil
---@field text string|nil       content query (a state matches when its own diff touches the text)

---@class LvimUndoPanelState
---@field handle table?             the live ui.tabs handle
---@field tree table?               the shared lvim-ui.tree handle
---@field src_buf integer?          the buffer whose history is shown
---@field src_win integer?          the window the panel opened from (scratch splits return here)
---@field mode "timeline"|"project" the active tab
---@field view "all"|"current"      the timeline view
---@field query string              the raw filter input
---@field filter LvimUndoFilter?    the parsed filter (nil = none)
---@field content_set table<integer, boolean>?  seqs whose diff matches filter.text
---@field marks table<integer, { tags: string[], checkpoints: string[] }>  validated marks by seq
---@field snap LvimUndoSnapshot?    the snapshot of the last render
---@field counts { shown: integer, total: integer }
---@field sel_seq integer?          the state under the timeline cursor
---@field sel_row LvimUndoMark?     the row under the project cursor
---@field preview_pan table?        the preview panel handle
---@field timer uv.uv_timer_t?      the preview debounce timer
---@field layout string?            session-sticky per-command layout override
local state = {
    mode = "timeline",
    view = "all",
    query = "",
    marks = {},
    counts = { shown = 0, total = 0 },
}

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-undo: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the panel is currently open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ─── the filter ───────────────────────────────────────────────────────────────

--- Parse the raw query: `#frag` = tag filter, `@hour`/`@today` = age, the rest = content text.
---@param q string
---@return LvimUndoFilter|nil  nil when the query is empty
local function parse_query(q)
    local f = { tags = {}, age = nil, text = nil }
    local words = {}
    for tok in q:gmatch("%S+") do
        if tok:sub(1, 1) == "#" and #tok > 1 then
            f.tags[#f.tags + 1] = tok:sub(2)
        elseif tok == "@hour" then
            f.age = "hour"
        elseif tok == "@today" then
            f.age = "today"
        else
            words[#words + 1] = tok
        end
    end
    if #words > 0 then
        f.text = table.concat(words, " ")
    end
    if #f.tags == 0 and not f.age and not f.text then
        return nil
    end
    return f
end

--- The seqs whose OWN change (the diff against their parent) touches `text` — the content search.
--- Walks at most `config.search.max_states` newest states through one batched undo walk; only the
--- +/- lines of each state's diff are searched (context would match everything the file contains).
---@param snap LvimUndoSnapshot
---@param text string
---@return table<integer, boolean>
local function content_matches(snap, text)
    local seqs = {}
    for seq in pairs(snap.all) do
        if seq > 0 then
            seqs[#seqs + 1] = seq
        end
    end
    table.sort(seqs, function(a, b)
        return a > b
    end)
    while #seqs > config.search.max_states do
        seqs[#seqs] = nil
    end
    local want, seen = {}, {}
    for _, seq in ipairs(seqs) do
        for _, s in ipairs({ seq, snap.all[seq].parent and snap.all[seq].parent.seq or 0 }) do
            if not seen[s] then
                seen[s] = true
                want[#want + 1] = s
            end
        end
    end
    table.sort(want)
    local texts = model.texts_at(state.src_buf, want)
    local needle = text:lower()
    local set = {}
    for _, seq in ipairs(seqs) do
        local s = snap.all[seq]
        local a = texts[s.parent and s.parent.seq or 0]
        local b = texts[seq]
        if a and b then
            local d = vim.text.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", {
                result_type = "unified",
                ctxlen = 0,
            })
            if type(d) == "string" then
                for line in vim.gsplit(d, "\n") do
                    local first = line:sub(1, 1)
                    if (first == "+" or first == "-") and line:lower():find(needle, 1, true) then
                        set[seq] = true
                        break
                    end
                end
            end
        end
    end
    return set
end

--- Whether a state passes the active filter.
---@param s LvimUndoState
---@return boolean
local function matches_filter(s)
    local f = state.filter
    if not f then
        return true
    end
    local m = state.marks[s.seq]
    for _, frag in ipairs(f.tags) do
        local hit = false
        if m then
            for _, list in ipairs({ m.tags, m.checkpoints }) do
                for _, name in ipairs(list) do
                    if name:lower():find(frag:lower(), 1, true) then
                        hit = true
                        break
                    end
                end
                if hit then
                    break
                end
            end
        end
        if not hit then
            return false
        end
    end
    if f.age == "hour" and os.time() - (s.time or 0) > 3600 then
        return false
    end
    if f.age == "today" and os.date("%Y-%m-%d", s.time or 0) ~= os.date("%Y-%m-%d") then
        return false
    end
    if f.text and not (state.content_set and state.content_set[s.seq]) then
        return false
    end
    return true
end

-- ─── node building ────────────────────────────────────────────────────────────

--- One badge cell list for a state's marks (checkpoints first, then tags), with 1-space gaps so
--- adjacent badge boxes never touch.
---@param seq integer
---@return { [1]: string, [2]: string }[]|nil
local function badges_of(seq)
    local m = state.marks[seq]
    if not m then
        return nil
    end
    local out = {}
    for _, name in ipairs(m.checkpoints) do
        if #out > 0 then
            out[#out + 1] = { " ", "LvimUndoTime" }
        end
        out[#out + 1] = { (" %s %s "):format(config.icons.checkpoint, name), "LvimUndoCheckpointBadge" }
    end
    for _, name in ipairs(m.tags) do
        if #out > 0 then
            out[#out + 1] = { " ", "LvimUndoTime" }
        end
        out[#out + 1] = { (" %s %s "):format(config.icons.tag, name), "LvimUndoTagBadge" }
    end
    return #out > 0 and out or nil
end

--- One tree node for an undo state (`children` = the fork's alternate branches, when any).
---@param s LvimUndoState
---@param children LvimUiTreeNode[]|nil
---@return LvimUiTreeNode
local function state_node(s, children)
    if s.seq > 0 then
        state.counts.shown = state.counts.shown + 1
    end
    local is_cur = state.snap ~= nil and s.seq == state.snap.seq_cur
    local icon = is_cur and config.icons.current or (s.save and config.icons.saved or config.icons.state)
    local icon_hl = is_cur and "LvimUndoCurrent" or (s.save and "LvimUndoSaved" or "LvimUndoSeq")
    local age = model.fmt_time(s.time, config.time_format, config.absolute_format)
    return {
        id = "s:" .. s.seq,
        label = s.seq == 0 and config.labels.origin or tostring(s.seq),
        icon = icon,
        icon_hl = icon_hl,
        label_hl = is_cur and "LvimUndoCurrent" or "LvimUndoSeq",
        detail = age ~= "" and age or nil,
        badges = badges_of(s.seq),
        kind = "state",
        data = { seq = s.seq },
        children = children,
    }
end

local node_for -- forward decl (node_for ⇄ chain_nodes recurse through the branch structure)

--- A chronological chain as newest-first tree nodes (each carrying its own fork children).
---@param chain LvimUndoState[]
---@return LvimUiTreeNode[]
local function chain_nodes(chain)
    local out = {}
    for i = #chain, 1, -1 do
        out[#out + 1] = node_for(chain[i])
    end
    return out
end

--- A state node WITH its alternate branches attached as children (newest branch first).
---@param s LvimUndoState
---@return LvimUiTreeNode
node_for = function(s)
    local kids = nil
    if #s.branches > 0 then
        kids = {}
        for bi = #s.branches, 1, -1 do
            vim.list_extend(kids, chain_nodes(s.branches[bi]))
        end
    end
    return state_node(s, kids)
end

--- The whole-tree view: the main chain newest-first, the origin row last.
---@param snap LvimUndoSnapshot
---@return LvimUiTreeNode[]
local function full_nodes(snap)
    local out = chain_nodes(snap.main)
    -- The origin carries any branch that forked before the first main-chain state.
    out[#out + 1] = node_for(snap.root)
    return out
end

--- The current-timeline view: only the states plain `u`/`<C-r>` can reach, flat, newest-first.
---@param snap LvimUndoSnapshot
---@return LvimUiTreeNode[]
local function current_nodes(snap)
    local path = model.current_path(snap)
    local seqs = {}
    for seq in pairs(path) do
        seqs[#seqs + 1] = seq
    end
    table.sort(seqs, function(a, b)
        return a > b
    end)
    local out = {}
    for _, seq in ipairs(seqs) do
        out[#out + 1] = state_node(snap.all[seq])
    end
    return out
end

--- The filtered view: matching states flat, newest-first (the origin is never a match target).
---@param snap LvimUndoSnapshot
---@return LvimUiTreeNode[]
local function filtered_nodes(snap)
    local seqs = {}
    for seq in pairs(snap.all) do
        if seq > 0 then
            seqs[#seqs + 1] = seq
        end
    end
    table.sort(seqs, function(a, b)
        return a > b
    end)
    local out = {}
    for _, seq in ipairs(seqs) do
        if matches_filter(snap.all[seq]) then
            out[#out + 1] = state_node(snap.all[seq])
        end
    end
    if #out == 0 then
        out[1] = { id = "s:none", label = config.labels.no_matches, icon = "", label_hl = "LvimUndoEmpty" }
    end
    return out
end

--- The project view: every stored mark across every file, newest first.
---@return LvimUiTreeNode[]
local function project_nodes()
    local rows = store.recent(config.project.limit)
    local out = {}
    for i, r in ipairs(rows) do
        local tail = vim.fn.fnamemodify(r.file, ":t")
        local rel = vim.fn.fnamemodify(r.file, ":~:.")
        local is_cp = r.kind == "checkpoint"
        local age = model.fmt_time(r.created or 0, config.time_format, config.absolute_format)
        local fi = iconlib.get(r.file, {}).glyph or ""
        out[#out + 1] = {
            id = "p:" .. (r.id or i),
            label = (r.name or "") ~= "" and r.name or tail,
            icon = is_cp and config.icons.checkpoint or config.icons.tag,
            icon_hl = is_cp and "LvimUndoCheckpointBadge" or "LvimUndoTagBadge",
            label_hl = "LvimUndoSeq",
            detail = ("%s %s  %d  %s"):format(fi, rel, r.seq, age),
            kind = "project",
            data = { row = r },
        }
    end
    state.counts.shown = #out
    if #out == 0 then
        out[1] = { id = "p:none", label = config.labels.empty_project, icon = "", label_hl = "LvimUndoEmpty" }
    end
    return out
end

-- ─── the tree header (file ➤ view ➤ filter) ──────────────────────────────────

--- The one-line status band above the tree + a blank air row, full width, header tinted.
---@param width integer
---@return string[] lines, table[] spans
local function header(width)
    local segs = {}
    if state.mode == "project" then
        segs[#segs + 1] = ("%s %s"):format(config.icons.project, config.titles.project)
    else
        local name = state.src_buf and vim.fn.fnamemodify(api.nvim_buf_get_name(state.src_buf), ":t") or ""
        segs[#segs + 1] = ("%s %s"):format(config.icons.panel, name)
        segs[#segs + 1] = state.view == "current" and config.labels.view_current or config.labels.view_all
        if state.query ~= "" then
            segs[#segs + 1] = ("%s %s"):format(config.icons.search, state.query)
        end
    end
    local line = " " .. table.concat(segs, " " .. config.icons.separator .. " ")
    local pad = width - vim.fn.strdisplaywidth(line)
    if pad > 0 then
        line = line .. string.rep(" ", pad)
    end
    return { line, "" }, { { 0, 0, -1, "LvimUndoHeader" } }
end

-- ─── the preview ──────────────────────────────────────────────────────────────

--- Render the preview pane for the current selection (the diff, or a project row's details).
local function render_preview()
    local pan = state.preview_pan
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    if state.mode == "project" then
        local r = state.sel_row
        if not r then
            diff.render_info(pan, { " " .. config.labels.no_selection }, { { 0, 0, -1, "LvimUndoEmpty" } })
            return
        end
        local age = model.fmt_time(r.created or 0, config.time_format, config.absolute_format)
        local lines = {
            (" %s %s"):format(r.kind == "checkpoint" and config.icons.checkpoint or config.icons.tag, r.name or ""),
            "",
            (" %s"):format(vim.fn.fnamemodify(r.file, ":~:.")),
            (" %s %d   %s %s"):format(config.icons.state, r.seq, config.icons.time, age),
        }
        diff.render_info(pan, lines, {
            { 0, 0, -1, r.kind == "checkpoint" and "LvimUndoCheckpointBadge" or "LvimUndoTagBadge" },
            { 2, 0, -1, "LvimUndoFile" },
            { 3, 0, -1, "LvimUndoTime" },
        })
        return
    end
    diff.render(pan, state.src_buf, state.sel_seq)
end

--- Debounced cursor-follow preview (the scrub).
local function schedule_preview()
    if not config.diff.preview_on_move then
        return
    end
    if not state.timer then
        state.timer = uv.new_timer()
    end
    if state.timer then
        state.timer:stop()
        state.timer:start(config.diff.debounce, 0, vim.schedule_wrap(render_preview))
    end
end

--- The preview content provider handed to `ui.tabs` (the chassis owns the window).
---@return table
local function preview_provider()
    return {
        ---@return integer width, integer height
        size = function()
            return math.floor(vim.o.columns * (1 - config.width)), 16
        end,
        update = function(pan)
            state.preview_pan = pan
            render_preview()
        end,
        keys = function(_, pan)
            state.preview_pan = pan
        end,
        on_close = function()
            state.preview_pan = nil
            diff.stop()
        end,
    }
end

-- ─── refresh ──────────────────────────────────────────────────────────────────

--- Reload the validated marks for the source buffer (a DB read — only on open / tag edits /
--- refresh / purge, never per render).
local function reload_marks()
    if state.src_buf and api.nvim_buf_is_valid(state.src_buf) then
        state.marks = tags.for_buffer(state.src_buf, model.snapshot(state.src_buf))
    else
        state.marks = {}
    end
end

--- Repaint everything from live data: the tree, the current-state mark, the border counter and
--- the preview. The ONE repaint path every action lands on.
function M.refresh()
    if not (M.is_open() and state.tree) then
        return
    end
    if state.snap then
        state.tree.mark(state.mode == "timeline" and ("s:" .. state.snap.seq_cur) or nil)
    end
    state.tree.refresh()
    if state.handle.recalc then
        state.handle.recalc() -- re-derives the header bands + the border counter
    end
    render_preview()
end

-- ─── actions ──────────────────────────────────────────────────────────────────

--- The selected timeline STATE node's seq (nil on placeholders / project rows).
---@return integer|nil
local function selected_seq()
    local n = state.tree and state.tree.selected()
    if n and n.kind == "state" and n.data then
        return n.data.seq
    end
    return nil
end

--- Restore the source buffer to undo state `seq` (`:undo N` jumps across branches natively).
---@param seq integer
local function restore_state(seq)
    local buf = state.src_buf
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    api.nvim_buf_call(buf, function()
        pcall(vim.cmd, ("silent undo %d"):format(seq))
    end)
    local file = api.nvim_buf_get_name(buf)
    log.add(("restored %s to seq %d"):format(vim.fn.fnamemodify(file, ":~:."), seq))
    log.event("Restore", { file = file, seq = seq })
    M.refresh()
end

--- Open a PROJECT row: close the panel, edit its file, and — when the stored state still exists in
--- that file's live tree (the `seq_time` staleness guard) — restore to it.
---@param row LvimUndoMark
local function open_project_row(row)
    M.close()
    if vim.fn.filereadable(row.file) == 0 then
        notify(("file no longer exists: %s"):format(row.file), vim.log.levels.WARN)
        return
    end
    -- `:edit` on a file already shown in a MODIFIED buffer is a reload and refuses with E37;
    -- bufadd + win_set_buf swaps the (possibly already-loaded) buffer in without touching it.
    local buf = vim.fn.bufadd(row.file)
    vim.fn.bufload(buf)
    api.nvim_win_set_buf(0, buf)
    vim.bo[buf].buflisted = true
    local snap = model.snapshot(buf)
    local s = snap.all[row.seq]
    if not (s and (s.time or 0) == (row.seq_time or 0)) then
        notify(
            ("state %d of %s no longer exists"):format(row.seq, vim.fn.fnamemodify(row.file, ":t")),
            vim.log.levels.WARN
        )
        return
    end
    api.nvim_buf_call(buf, function()
        pcall(vim.cmd, ("silent undo %d"):format(row.seq))
    end)
    log.add(("opened %s at seq %d"):format(vim.fn.fnamemodify(row.file, ":~:."), row.seq))
    log.event("Restore", { file = row.file, seq = row.seq })
end

--- The restore key / tree activation: restore a state, or open a project row.
local function restore_selected()
    local n = state.tree and state.tree.selected()
    if not (n and n.data) then
        return
    end
    if n.kind == "project" then
        open_project_row(n.data.row)
    elseif n.kind == "state" then
        restore_state(n.data.seq)
    end
end

--- Step the REAL buffer's history one change back/forward from inside the panel; the panel follows.
---@param dir "undo"|"redo"
local function step(dir)
    local buf = state.src_buf
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    api.nvim_buf_call(buf, function()
        pcall(vim.cmd, "silent " .. dir)
    end)
    log.event("Step", { file = api.nvim_buf_get_name(buf), dir = dir })
    M.refresh()
end

--- Edit the selected state's tags: one input, space-separated names, empty clears.
local function edit_tags()
    local seq = selected_seq()
    if not seq or not state.snap then
        return
    end
    local s = state.snap.all[seq]
    if not s then
        return
    end
    if not tags.file_of(state.src_buf) then
        notify("tags need a file behind the buffer", vim.log.levels.WARN)
        return
    end
    local existing = state.marks[seq] and table.concat(state.marks[seq].tags, " ") or ""
    ui.input({
        title = " " .. config.titles.tag,
        default = existing,
        callback = function(confirmed, value)
            if confirmed ~= true then
                return
            end
            local names = {}
            for tok in tostring(value or ""):gmatch("%S+") do
                names[#names + 1] = tok
            end
            if tags.set(state.src_buf, s, names) then
                reload_marks()
                M.refresh()
            end
        end,
    })
end

--- The `/` filter input: parse tag/age/content tokens; a content token runs the batched search.
local function open_search()
    ui.input({
        title = " " .. config.titles.search,
        default = state.query,
        callback = function(confirmed, value)
            if confirmed ~= true then
                return
            end
            state.query = vim.trim(tostring(value or ""))
            state.filter = parse_query(state.query)
            state.content_set = nil
            if state.filter and state.filter.text and state.src_buf then
                state.content_set = content_matches(model.snapshot(state.src_buf), state.filter.text)
            end
            M.refresh()
        end,
    })
end

--- Toggle the timeline view (whole tree ⇄ current timeline).
local function toggle_view()
    if state.mode ~= "timeline" then
        return
    end
    state.view = state.view == "all" and "current" or "all"
    M.refresh()
end

--- Open the selected state in a read-only SCRATCH buffer beside the source window — look at (and
--- yank from) an old state without touching the live buffer. `diffmode` adds `:diffthis` on both
--- windows; diff mode is unwound when the scratch closes.
---@param diffmode boolean
local function open_scratch(diffmode)
    local seq = selected_seq()
    local buf = state.src_buf
    if not (seq and buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    local lines = model.text_at(buf, seq)
    if not lines then
        notify("could not read that state", vim.log.levels.WARN)
        return
    end
    local src_ft = vim.bo[buf].filetype
    local src_name = api.nvim_buf_get_name(buf)
    local src_win = state.src_win
    M.close()
    if src_win and api.nvim_win_is_valid(src_win) then
        api.nvim_set_current_win(src_win)
    end
    vim.cmd("vsplit")
    local scratch_win = api.nvim_get_current_win()
    local sbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
    pcall(
        api.nvim_buf_set_name,
        sbuf,
        ("%s://%s@%d"):format(config.titles.scratch, vim.fn.fnamemodify(src_name, ":t"), seq)
    )
    vim.bo[sbuf].bufhidden = "wipe"
    vim.bo[sbuf].modifiable = false
    -- Highlight by LANGUAGE, never by setting 'filetype' (no FileType autocmds → no LSP attach on a
    -- transient scratch) — the shared preview seam.
    uipreview.set_syntax(sbuf, src_ft)
    api.nvim_win_set_buf(scratch_win, sbuf)
    if diffmode and src_win and api.nvim_win_is_valid(src_win) then
        api.nvim_win_call(scratch_win, function()
            vim.cmd("diffthis")
        end)
        api.nvim_win_call(src_win, function()
            vim.cmd("diffthis")
        end)
        -- Unwind the source window's diff mode when the scratch goes away.
        api.nvim_create_autocmd("BufWipeout", {
            buffer = sbuf,
            once = true,
            callback = function()
                if src_win and api.nvim_win_is_valid(src_win) then
                    api.nvim_win_call(src_win, function()
                        pcall(vim.cmd, "diffoff")
                    end)
                end
            end,
        })
    end
end

-- ─── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description rows shown by `g?` (order = display order).
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "restore", "restore this state" },
    { "undo", "undo one step (the panel follows)" },
    { "redo", "redo one step" },
    { "preview", "refresh the diff preview" },
    { "tag", "edit this state's tags" },
    { "toggle_view", "toggle whole tree / current timeline" },
    { "search", "filter: #tag, @hour, @today, content text" },
    { "scratch", "open this state in a scratch buffer" },
    { "diffsplit", "diff this state against the buffer" },
    { "expand", "expand a branch" },
    { "collapse", "collapse a branch / go to the fork" },
    { "refresh", "refresh the timeline" },
    { "help", "this help" },
    { "close", "close" },
}

--- Show the keymap cheatsheet — full-width column-aligned rows (KEY box + DESCRIPTION box),
--- striped odd/even per the canon; the ACTIVE row's description rises to the key tint so the row
--- reads as one solid block; the hardware cursor stays hidden.
local function show_help()
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = config.keys[e[1]]
        if lhs then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    local kw, dw = 0, 0
    for _, r in ipairs(items) do
        kw = math.max(kw, vim.fn.strdisplaywidth(r[1]))
        dw = math.max(dw, vim.fn.strdisplaywidth(r[2]))
    end
    local keybox = kw + 4 -- 2 spaces left of the key + the key + ≥2 right — the aligned KEY column

    local pan
    local provider = {
        hide_cursor = true,
        size = function()
            return keybox + dw + 4, #items
        end,
        render = function(width)
            local cur = (pan and pan.win and api.nvim_win_is_valid(pan.win)) and api.nvim_win_get_cursor(pan.win)[1]
                or 1
            local lines, hls = {}, {}
            for i, r in ipairs(items) do
                local side = (i % 2 == 1) and "Odd" or "Even"
                local kcell = "  " .. r[1]
                kcell = kcell .. string.rep(" ", math.max(0, keybox - #kcell))
                local dcell = "  " .. r[2]
                dcell = dcell .. string.rep(" ", math.max(0, width - keybox - #dcell))
                lines[i] = kcell .. dcell
                local desc = (i == cur) and ("LvimUndoHelpDescActive" .. side) or ("LvimUndoHelpDesc" .. side)
                hls[#hls + 1] = { i - 1, 0, #kcell, "LvimUndoHelpKey" .. side }
                hls[#hls + 1] = { i - 1, #kcell, #lines[i], desc }
            end
            return lines, hls
        end,
        keys = function(_, p)
            pan = p
            -- Re-render so the brighter active-row tint follows the (hidden) cursor.
            api.nvim_create_autocmd("CursorMoved", {
                buffer = p.buf,
                callback = function()
                    if p.refresh then
                        p.refresh()
                    end
                end,
            })
        end,
    }
    surface.open({
        mode = "float",
        border = surface.FRAME_BORDER,
        title = " " .. config.titles.help,
        panel_border = "none",
        size = { width = { auto = true, max = 0.7 }, height = { auto = true, max = 0.7 } },
        close_keys = { config.keys.close, "<Esc>", config.keys.help },
        content = { blocks = { { id = "help", provider = provider } } },
        footer = {
            bars = {
                {
                    items = {
                        {
                            key = config.keys.close,
                            name = config.labels.close,
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
    })
end

-- ─── the tree + its keys ──────────────────────────────────────────────────────

--- Bind the panel keys on the shared content buffer (the tree's `on_keys` hook — fired once by
--- the chassis, live in both tabs since the tabs share the one tree).
---@param map fun(lhs: string|string[], fn: fun())
local function wire_keys(map)
    local k = config.keys
    map(k.restore, restore_selected)
    map(k.undo, function()
        step("undo")
    end)
    map(k.redo, function()
        step("redo")
    end)
    map(k.tag, edit_tags)
    map(k.refresh, function()
        reload_marks()
        M.refresh()
    end)
    map(k.toggle_view, toggle_view)
    map(k.search, open_search)
    map(k.scratch, function()
        open_scratch(false)
    end)
    map(k.diffsplit, function()
        open_scratch(true)
    end)
    map(k.preview, render_preview)
    map(k.help, show_help)
end

--- Build the shared tree handle (one per open — fold state resets with the panel).
---@return table
local function build_tree()
    return ui.tree({
        root = function()
            state.counts.shown = 0
            if state.mode == "project" then
                local nodes = project_nodes()
                state.counts.total = state.counts.shown
                return nodes
            end
            local src = state.src_buf
            if not (src and api.nvim_buf_is_valid(src)) then
                return {}
            end
            local snap = model.snapshot(src)
            state.snap = snap
            state.counts.total = snap.total
            if state.filter then
                return filtered_nodes(snap)
            elseif state.view == "current" then
                return current_nodes(snap)
            end
            return full_nodes(snap)
        end,
        default_expanded = true, -- branches start visible; a fold collapses an abandoned line
        connectors = true,
        scrollbar = true,
        hide_cursor = true,
        filetype = config.filetype,
        keys = false, -- every key is bound in wire_keys from config.keys (restore ≠ expand)
        header = header,
        empty = config.labels.empty_timeline,
        on_activate = restore_selected, -- the mouse click's activation
        on_move = function(node)
            if state.mode == "project" then
                state.sel_row = node and node.data and node.data.row or nil
            else
                state.sel_seq = node and node.data and node.data.seq or nil
            end
            schedule_preview()
        end,
        on_keys = function(map, _, _, t)
            -- Expand ONLY — never the tree's expand-or-ACTIVATE default. In a file tree activating a
            -- leaf opens a file; here it RESTORES the buffer to that state, so `l` on any ordinary
            -- state would silently rewrite the buffer and re-root the tree (which reads as the rows
            -- reordering themselves). Restoring is `<CR>`'s job, and nothing else's.
            map(config.keys.expand, function()
                local n = t.selected()
                if n then
                    t.expand(n.id)
                end
            end)
            map(config.keys.collapse, t.collapse_or_parent)
            wire_keys(map)
        end,
    })
end

--- Land the (hidden) cursor on the mode's natural row — the CURRENT state (timeline) or the first
--- stored row (project) — and prime the selection + preview from it. Scheduled after open and
--- after a tab switch: the cursor starts on the header otherwise, where `<CR>` has nothing to act
--- on (the CursorMoved clamp only rescues it once the user moves).
local function focus_initial()
    if not (M.is_open() and state.tree) then
        return
    end
    if state.mode == "timeline" then
        if state.snap then
            state.tree.mark("s:" .. state.snap.seq_cur, { move_cursor = true })
            state.tree.focus("s:" .. state.snap.seq_cur)
            state.sel_seq = state.snap.seq_cur
            render_preview()
        end
    else
        local first = state.tree.visible()[1]
        if first and first.data and first.data.row then
            state.tree.focus(first.id)
            state.sel_row = first.data.row
            render_preview()
        end
    end
end

-- ─── open / close ─────────────────────────────────────────────────────────────

--- A provider-tab wrapper for `mode`: stamps the active mode before delegating to the ONE shared
--- tree provider, so a tab switch re-roots the same tree (see the module header).
---@param mode "timeline"|"project"
---@return table
local function tab_provider(mode)
    -- The surface reads a provider's DECLARATIVE flags off the object it is handed — this wrapper —
    -- never off the delegate behind it. So forward the tree's own flags rather than re-declaring a
    -- subset: dropping `cursorline` leaves the window with no selection bar, and with `hide_cursor`
    -- there is then nothing at all marking the row the (hidden) cursor is on.
    local tp = state.tree.provider
    return {
        hide_cursor = tp.hide_cursor,
        cursorline = tp.cursorline,
        filetype = tp.filetype,
        size = function()
            return state.tree.provider.size()
        end,
        update = function(pan, L)
            local switched = state.mode ~= mode
            if switched then
                state.mode = mode
                state.sel_seq, state.sel_row = nil, nil
            end
            state.tree.provider.update(pan, L)
            if state.snap then
                state.tree.mark(mode == "timeline" and ("s:" .. state.snap.seq_cur) or nil)
            end
            if switched then
                vim.schedule(focus_initial)
            else
                render_preview()
            end
        end,
        keys = function(map, pan, st)
            state.tree.provider.keys(map, pan, st)
        end,
        on_close = function(pan)
            state.tree.provider.on_close(pan)
        end,
    }
end

--- One footer chip list (clickable legend; the REAL keys live on the panel buffer, so every chip
--- is `no_hotkey` — a chip's key cell is display only).
---@param mode "timeline"|"project"
---@return table[]
local function footer_of(mode)
    local k, l = config.keys, config.labels
    local chips = {}
    local function chip(key, label, run)
        chips[#chips + 1] = { key = key, label = label, no_hotkey = true, run = run }
    end
    chip(k.restore, l.restore, restore_selected)
    if mode == "timeline" then
        chip(k.tag, l.tag, edit_tags)
        chip(k.toggle_view, l.view, toggle_view)
        chip(k.search, l.search, open_search)
        chip(k.scratch, l.scratch, function()
            open_scratch(false)
        end)
    end
    chips[#chips + 1] = { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
    chip(k.close .. "/Esc", l.close, function(st)
        st.close()
    end)
    return chips
end

--- Open the panel for the CURRENT buffer.
---@param opts LvimUndoOpenOpts?
function M.open(opts)
    opts = opts or {}
    if M.is_open() then
        M.close()
    end
    local buf = api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= "" then
        notify("not a file buffer", vim.log.levels.WARN)
        return
    end
    if not vim.bo[buf].modifiable then
        notify("buffer is not modifiable — the history cannot be walked", vim.log.levels.WARN)
        return
    end
    if opts.layout then
        state.layout = opts.layout -- a per-command override is sticky for the session
    end
    state.src_buf = buf
    state.src_win = api.nvim_get_current_win()
    state.mode = opts.tab or "timeline"
    state.view = config.view
    state.query, state.filter, state.content_set = "", nil, nil
    state.sel_seq, state.sel_row = nil, nil
    state.counts = { shown = 0, total = 0 }
    reload_marks()
    state.tree = build_tree()

    state.handle = ui.tabs({
        title = { icon = config.icons.panel, text = config.titles.panel },
        title_count = function()
            return { current = state.counts.shown, total = state.counts.total }
        end,
        tabs = {
            {
                label = config.titles.timeline,
                icon = config.icons.panel,
                name = "timeline",
                provider = tab_provider("timeline"),
                footer = footer_of("timeline"),
            },
            {
                label = config.titles.project,
                icon = config.icons.project,
                name = "project",
                provider = tab_provider("project"),
                footer = footer_of("project"),
            },
        },
        tab_selector = state.mode,
        layout = state.layout or config.layout,
        content_width = config.width,
        preview = preview_provider(),
        preview_side = config.preview_side,
        close_keys = { config.keys.close, "<Esc>" },
        callback = function()
            if state.timer then
                pcall(function()
                    state.timer:stop()
                    state.timer:close()
                end)
                state.timer = nil
            end
            diff.stop()
            model.release() -- drop the mirror buffers the undo walk read the states from
            state.handle, state.tree, state.preview_pan = nil, nil, nil
        end,
    })

    -- Land the (hidden) cursor on the mode's natural row and prime the preview.
    vim.schedule(focus_initial)
end

--- Close the panel (a no-op when it is not open).
function M.close()
    if M.is_open() then
        state.handle.close()
    end
end

--- Toggle the panel.
---@param opts LvimUndoOpenOpts?
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

return M
