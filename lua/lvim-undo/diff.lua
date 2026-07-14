-- lvim-undo.diff: the diff-preview engines. Renders the difference between the SELECTED undo state
-- and the CURRENT one into the chassis preview panel, through one of two paths:
--
--   • NATIVE (`vim.text.diff`, the default) — no external process. The unified text (or, with
--     `result_type = "indices"`, the hunk summaries) is painted into the panel's own scratch
--     buffer with per-line highlight groups, via the frame's own painter (`surface.paint`).
--   • EXTERNAL (`delta` / `difft` / `diff`) — the two states are written to temp files (carrying
--     the source file's extension, so the tool can syntax-highlight) and the tool runs on a PTY
--     (`jobstart { pty = true, width = <panel> }`), its ANSI output streamed into an
--     `nvim_open_term` channel on a fresh scratch buffer swapped into the preview window — the
--     lvim-tasks terminal-swap seam. A PTY (not a pipe) is what makes delta emit colour and size
--     its side-by-side layout to the panel; `nvim_open_term` (not a `term = true` job buffer) is
--     what renders ANSI without a "[Process exited]" tail.
--
-- One render at a time: a newer request stops the previous job and wipes its buffer, so scrubbing
-- the timeline never stacks processes.
--
---@module "lvim-undo.diff"

local config = require("lvim-undo.config")
local model = require("lvim-undo.model")
local surface = require("lvim-ui.surface")
local uipreview = require("lvim-ui.preview")

local M = {}

local api = vim.api

-- The preview placeholder's extmark namespace (render_empty wants the caller's own).
local NS = api.nvim_create_namespace("lvim-undo-preview")

---@class LvimUndoDiffState
---@field job integer|nil        the running external-tool job id
---@field term_buf integer|nil   the terminal buffer currently swapped into the preview
---@field tmp_a string|nil       reusable temp file for the selected state
---@field tmp_b string|nil       reusable temp file for the current state
local state = {}

--- Stop the running external job and forget its terminal buffer. The buffer itself is NEVER
--- deleted here: it may still be DISPLAYED in the preview float, and wiping a float's buffer
--- closes the float — which cascades into the whole frame tearing down. Terminal buffers carry
--- `bufhidden = wipe`, so swapping the next buffer into the window (or the window closing)
--- reclaims them; forgetting the handle is enough.
function M.stop()
    if state.job then
        pcall(vim.fn.jobstop, state.job)
        state.job = nil
    end
    state.term_buf = nil
end

--- Show the preview panel's OWN scratch buffer (the native/placeholder surface) — a previous
--- external render may have swapped a terminal buffer into the window.
---@param pan table
local function own_buffer(pan)
    if pan.buf and api.nvim_buf_is_valid(pan.buf) and api.nvim_win_get_buf(pan.win) ~= pan.buf then
        api.nvim_win_set_buf(pan.win, pan.buf)
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"
    end
end

--- Paint a one-line placeholder (the canonical empty-preview row).
---@param pan table
---@param msg string
local function placeholder(pan, msg)
    M.stop()
    own_buffer(pan)
    uipreview.render_empty(pan.buf, NS, msg)
end

-- ─── the native engine ────────────────────────────────────────────────────────

--- Render `vim.text.diff` output into the panel's scratch buffer with per-line groups.
---@param pan table
---@param a string[]  the selected state's lines
---@param b string[]  the current state's lines
local function render_native(pan, a, b)
    M.stop()
    own_buffer(pan)
    local n = config.diff.native
    local res = vim.text.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", {
        result_type = n.result_type,
        ctxlen = n.ctxlen,
        algorithm = n.algorithm,
    })
    local lines, hls = {}, {}
    if type(res) == "table" then
        -- result_type = "indices": one summary row per hunk.
        for _, h in ipairs(res) do
            lines[#lines + 1] = ("@@ -%d,%d +%d,%d @@"):format(h[1], h[2], h[3], h[4])
            hls[#hls + 1] = { #lines - 1, 0, -1, "LvimUndoHunk" }
        end
    elseif type(res) == "string" and res ~= "" then
        for line in vim.gsplit(res, "\n") do
            lines[#lines + 1] = line
            local first = line:sub(1, 1)
            local group = (first == "+" and "LvimUndoAdded")
                or (first == "-" and "LvimUndoRemoved")
                or (first == "@" and "LvimUndoHunk")
                or "LvimUndoContext"
            hls[#hls + 1] = { #lines - 1, 0, -1, group }
        end
        -- vim.gsplit leaves one empty tail after the final newline — drop it.
        if lines[#lines] == "" then
            lines[#lines] = nil
            hls[#hls] = nil
        end
    end
    if #lines == 0 then
        uipreview.render_empty(pan.buf, NS, config.labels.no_diff)
        return
    end
    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
    surface.paint(pan, lines, hls)
end

-- ─── the external engines ─────────────────────────────────────────────────────

--- The reusable temp-file pair, stamped with the source file's extension so delta/difft can
--- syntax-highlight the states.
---@param src_name string
---@return string a, string b
local function temp_files(src_name)
    if not state.tmp_a then
        state.tmp_a, state.tmp_b = vim.fn.tempname(), vim.fn.tempname()
    end
    local ext = vim.fn.fnamemodify(src_name, ":e")
    local suffix = ext ~= "" and ("." .. ext) or ""
    return state.tmp_a .. suffix, state.tmp_b .. suffix
end

--- Run an external tool on the two states and stream its ANSI output into a fresh terminal buffer
--- swapped into the preview window.
---@param pan table
---@param engine string    "delta" | "difft" | "diff" (the binary name)
---@param src_name string  the source file's name (for the temp extension)
---@param a string[]
---@param b string[]
local function render_external(pan, engine, src_name, a, b)
    M.stop()
    local fa, fb = temp_files(src_name)
    if not pcall(vim.fn.writefile, a, fa) or not pcall(vim.fn.writefile, b, fb) then
        placeholder(pan, config.labels.no_diff)
        return
    end
    local argv = { engine }
    vim.list_extend(argv, config.diff.embed[engine] or {}) -- render into US, never into a pager
    local bg = (config.diff.background[engine] or {})[vim.o.background]
    if bg then
        argv[#argv + 1] = bg -- tell it the theme, so it never QUERIES our PTY and waits out the timeout
    end
    vim.list_extend(argv, config.diff.external[engine] or {})
    argv[#argv + 1] = fa
    argv[#argv + 1] = fb

    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local chan = api.nvim_open_term(buf, {})
    api.nvim_win_set_buf(pan.win, buf)
    vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"
    vim.wo[pan.win].number = false
    vim.wo[pan.win].relativenumber = false
    vim.wo[pan.win].signcolumn = "no"
    state.term_buf = buf

    state.job = vim.fn.jobstart(argv, {
        pty = true,
        width = api.nvim_win_get_width(pan.win),
        height = api.nvim_win_get_height(pan.win),
        on_stdout = function(_, data)
            if state.term_buf == buf and api.nvim_buf_is_valid(buf) then
                pcall(api.nvim_chan_send, chan, table.concat(data, "\n"))
            end
        end,
        -- delta/diff exit non-zero when the files differ — that IS the success case, so the exit
        -- code is ignored; the job id is only cleared.
        on_exit = function(job)
            if state.job == job then
                state.job = nil
            end
        end,
    })
    if state.job <= 0 then
        state.job = nil
        placeholder(pan, ("%s failed to start"):format(engine))
    end
end

-- ─── the public render ────────────────────────────────────────────────────────

--- Paint plain INFO lines into the preview (the project view's row details) — same buffer
--- ownership as the native path, so leftover diff extmarks never bleed under the info.
---@param pan table
---@param lines string[]
---@param hls table[]  { row, col, end_col|-1, hl } spans
function M.render_info(pan, lines, hls)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    if api.nvim_get_current_win() == pan.win then
        return
    end
    M.stop()
    own_buffer(pan)
    api.nvim_buf_clear_namespace(pan.buf, NS, 0, -1)
    surface.paint(pan, lines, hls)
end

--- Render the diff between undo state `seq` and the buffer's CURRENT state into the preview panel.
--- `seq = nil` (no selectable row under the cursor) paints the placeholder.
---@param pan table       the preview panel (`pan.win` / `pan.buf`)
---@param buf integer     the source buffer
---@param seq integer|nil the selected state
function M.render(pan, buf, seq)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    -- Never yank the buffer out from under the user while they are INSIDE the preview.
    if api.nvim_get_current_win() == pan.win then
        return
    end
    if seq == nil or not (buf and api.nvim_buf_is_valid(buf)) then
        placeholder(pan, config.labels.no_selection)
        return
    end
    local cur = vim.fn.undotree(buf).seq_cur or 0
    local texts = model.texts_at(buf, { seq, cur })
    local a, b = texts[seq], texts[cur]
    if not (a and b) then
        placeholder(pan, config.labels.no_selection)
        return
    end
    -- Identical states short-circuit to the canonical placeholder — an external tool would render
    -- an empty terminal (blank pane) instead of saying so.
    local same = #a == #b
    if same then
        for i = 1, #a do
            if a[i] ~= b[i] then
                same = false
                break
            end
        end
    end
    if same then
        placeholder(pan, config.labels.no_diff)
        return
    end
    local engine = config.diff.engine
    if engine ~= "native" and vim.fn.executable(engine) == 1 then
        render_external(pan, engine, api.nvim_buf_get_name(buf), a, b)
    else
        render_native(pan, a, b)
    end
end

return M
