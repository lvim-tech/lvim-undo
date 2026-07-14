-- lvim-undo.store: metadata persistence + undofile management.
-- The plugin's OWN sqlite database (via the set's `lvim-utils.store` seam, under
-- `stdpath("data")/lvim-undo/`) holds ONE table, `marks`: a row per tag or named checkpoint, keyed
-- by (file, seq, seq_time). The `seq_time` is the undo entry's own timestamp — a purged/rewritten
-- undofile renumbers its states, so a stored row whose time no longer matches the live entry is
-- STALE and is filtered out on read; stale tags can never resurrect. With `persist.tags = false`
-- (or sqlite.lua missing) the same API runs over an in-memory table, so tags become session-only
-- without any caller guarding.
--
-- Undofile MANAGEMENT also lives here: the purge operations (this buffer / all undofiles — each
-- drops the file(s), the in-memory history and the stored marks together) and the persistence
-- FILTER (max file size / excluded filetypes → `undofile` off for that buffer; `buftype ~= ""`
-- chrome never has persistent undo by construction).
--
---@module "lvim-undo.store"

local config = require("lvim-undo.config")
local log = require("lvim-undo.log")

local M = {}

local api = vim.api

---@class LvimUndoMark
---@field id integer|nil    the db row id (nil on the memory backend)
---@field file string       normalized absolute path
---@field seq integer       the undo sequence number the mark points at
---@field seq_time integer  the undo entry's own timestamp (the staleness guard)
---@field kind "tag"|"checkpoint"
---@field name string
---@field created integer|nil  epoch seconds the mark was written (stamped by `add` when absent)

local SCHEMA = {
    id = { "integer", primary = true, autoincrement = true },
    file = { "text", required = true },
    seq = { "integer", required = true },
    seq_time = { "integer" },
    kind = { "text" },
    name = { "text" },
    created = { "integer" },
}

---@type table?  the lvim-utils.store handle (nil = the memory backend)
local db = nil
local opened = false

---@type LvimUndoMark[]  the session-only fallback rows (memory backend)
local mem = {}

--- Open the store lazily (once). Falls back to the in-memory table when persistence is off or
--- sqlite.lua is unavailable — the API is identical either way.
---@return table?  the store handle or nil (memory backend)
local function ensure()
    if opened then
        return db
    end
    opened = true
    if not config.persist.tags then
        return nil
    end
    local ok, store = pcall(require, "lvim-utils.store")
    if not ok or not store.available() then
        return nil
    end
    db = store.new({
        backend = "sqlite",
        name = "lvim-undo",
        version = 1,
        tables = { marks = SCHEMA },
    })
    if not (db and db:is_open()) then
        db = nil
    end
    return db
end

--- Whether marks persist across restarts (the sqlite backend actually opened).
---@return boolean
function M.persistent()
    return ensure() ~= nil
end

-- ─── marks CRUD ───────────────────────────────────────────────────────────────

--- Add one mark.
---@param mark LvimUndoMark
function M.add(mark)
    mark.created = mark.created or os.time()
    local s = ensure()
    if s then
        s:insert("marks", {
            file = mark.file,
            seq = mark.seq,
            seq_time = mark.seq_time,
            kind = mark.kind,
            name = mark.name,
            created = mark.created,
        })
    else
        mem[#mem + 1] = mark
    end
end

--- Every mark for `file` (any kind), unvalidated — the caller filters stale rows against the live
--- undo tree via `seq_time`.
---@param file string
---@return LvimUndoMark[]
function M.for_file(file)
    local s = ensure()
    if s then
        local rows = s:find("marks", { file = file })
        return (type(rows) == "table") and rows or {}
    end
    local out = {}
    for _, m in ipairs(mem) do
        if m.file == file then
            out[#out + 1] = m
        end
    end
    return out
end

--- Replace the TAG set of one state (file, seq, seq_time) with `names` — the panel's tag editor
--- writes the whole set at once; an empty list clears the state's tags.
---@param file string
---@param seq integer
---@param seq_time integer
---@param names string[]
function M.set_tags(file, seq, seq_time, names)
    local s = ensure()
    if s then
        s:remove("marks", { file = file, seq = seq, kind = "tag" })
        for _, name in ipairs(names) do
            s:insert(
                "marks",
                { file = file, seq = seq, seq_time = seq_time, kind = "tag", name = name, created = os.time() }
            )
        end
    else
        for i = #mem, 1, -1 do
            local m = mem[i]
            if m.file == file and m.seq == seq and m.kind == "tag" then
                table.remove(mem, i)
            end
        end
        for _, name in ipairs(names) do
            mem[#mem + 1] =
                { file = file, seq = seq, seq_time = seq_time, kind = "tag", name = name, created = os.time() }
        end
    end
end

--- The newest marks ACROSS every file (the project checkpoints view), newest first.
---@param limit integer
---@return LvimUndoMark[]
function M.recent(limit)
    local s = ensure()
    if s then
        local rows = s:find("marks", nil, { order_by = { desc = "created" }, limit = limit })
        return (type(rows) == "table") and rows or {}
    end
    local out = vim.list_extend({}, mem)
    table.sort(out, function(a, b)
        return (a.created or 0) > (b.created or 0)
    end)
    while #out > limit do
        out[#out] = nil
    end
    return out
end

--- Drop every stored mark for `file` (a purge drops the metadata with the history).
---@param file string
function M.drop_file(file)
    local s = ensure()
    if s then
        s:remove("marks", { file = file })
    else
        for i = #mem, 1, -1 do
            if mem[i].file == file then
                table.remove(mem, i)
            end
        end
    end
end

--- Drop EVERY stored mark (the purge-all companion).
function M.drop_all()
    local s = ensure()
    if s then
        s:exec("DELETE FROM marks")
    end
    mem = {}
end

-- ─── undofile purge ───────────────────────────────────────────────────────────

--- Clear a buffer's IN-MEMORY undo history — the documented `:h clear-undo` mechanism: drop
--- 'undolevels' to -1, make a no-op change (which flushes the tree), and restore. The text is
--- untouched; the transient change is wrapped `noautocmd` and the `modified` flag is restored, so
--- the round trip is invisible.
---@param buf integer
local function clear_memory(buf)
    if not vim.bo[buf].modifiable then
        return
    end
    api.nvim_buf_call(buf, function()
        local ul = vim.bo[buf].undolevels
        local was_modified = vim.bo[buf].modified
        vim.bo[buf].undolevels = -1
        pcall(vim.cmd, [[noautocmd silent execute "normal! a \<BS>\<Esc>"]])
        vim.bo[buf].undolevels = ul
        vim.bo[buf].modified = was_modified
    end)
end

--- Purge THIS buffer's undo history: its undofile on disk, the in-memory tree, and its stored
--- marks. Returns false (with a reason) on a buffer that has no file behind it.
---@param buf integer
---@return boolean ok, string? err
function M.purge_buffer(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return false, "invalid buffer"
    end
    local file = api.nvim_buf_get_name(buf)
    if file == "" or vim.bo[buf].buftype ~= "" then
        return false, "not a file buffer"
    end
    local undofile = vim.fn.undofile(file)
    if vim.fn.filereadable(undofile) == 1 then
        pcall(vim.fn.delete, undofile)
    end
    clear_memory(buf)
    M.drop_file(vim.fs.normalize(file))
    log.add(("purged undo history of %s"):format(vim.fn.fnamemodify(file, ":~:.")))
    log.event("Purge", { scope = "buffer", file = file })
    return true
end

--- Purge ALL undofiles (every file in every 'undodir' directory), every stored mark, and the
--- CURRENT buffer's in-memory history (other loaded buffers keep theirs until reload — Neovim has
--- no seam to flush another buffer's tree without touching it).
---@return integer removed  how many undofiles were deleted
function M.purge_all()
    local removed = 0
    for dir in tostring(vim.o.undodir):gmatch("[^,]+") do
        dir = vim.fs.normalize(dir)
        if vim.fn.isdirectory(dir) == 1 then
            for name, kind in vim.fs.dir(dir) do
                if kind == "file" then
                    if pcall(vim.fn.delete, dir .. "/" .. name) then
                        removed = removed + 1
                    end
                end
            end
        end
    end
    M.drop_all()
    local cur = api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "" and api.nvim_buf_get_name(cur) ~= "" then
        clear_memory(cur)
    end
    log.add(("purged all undofiles (%d removed)"):format(removed))
    log.event("Purge", { scope = "all", removed = removed })
    return removed
end

-- ─── the persistence filter ───────────────────────────────────────────────────

--- Why THIS buffer gets no persistent undo, or nil when it does. The verdict the autocmd guard
--- enforces and `:checkhealth lvim-undo` reports.
---@param buf integer
---@return string|nil reason
function M.exclusion_reason(buf)
    if vim.bo[buf].buftype ~= "" then
        return ("buftype %q is chrome, never content"):format(vim.bo[buf].buftype)
    end
    local ft = vim.bo[buf].filetype
    for _, ex in ipairs(config.persist.exclude_filetypes) do
        if ft == ex then
            return ("filetype %q is excluded (persist.exclude_filetypes)"):format(ft)
        end
    end
    local max = config.persist.max_file_size
    if type(max) == "number" and max > 0 then
        local name = api.nvim_buf_get_name(buf)
        local size = name ~= "" and vim.fn.getfsize(name) or 0
        if size > max then
            return ("file size %d exceeds persist.max_file_size (%d)"):format(size, max)
        end
    end
    return nil
end

--- Install the persistence-filter autocmds: an excluded buffer gets `undofile` turned OFF (the
--- filter only ever disables — whether persistent undo is on at all stays the user's 'undofile'
--- choice). Runs on read/creation and again on FileType (the filetype lands after BufReadPost).
function M.setup_filter()
    local group = api.nvim_create_augroup("LvimUndoPersistFilter", { clear = true })
    api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "FileType" }, {
        group = group,
        callback = function(ev)
            local buf = ev.buf
            if not api.nvim_buf_is_valid(buf) then
                return
            end
            if vim.bo[buf].buftype == "" and M.exclusion_reason(buf) ~= nil then
                vim.bo[buf].undofile = false
            end
        end,
        desc = "lvim-undo: disable persistent undo for excluded buffers",
    })
end

return M
