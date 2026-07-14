-- lvim-undo.tags: tags + named checkpoints as SEEN by the panel — the validation layer between the
-- raw store rows and the live undo tree. A stored mark is only real if its (seq, seq_time) pair
-- still matches an entry in the buffer's current tree: seq numbers are reused after a purge or a
-- history rewrite, so the timestamp is what keeps a stale row from resurrecting on a new state
-- that happens to wear the same number.
--
---@module "lvim-undo.tags"

local store = require("lvim-undo.store")
local log = require("lvim-undo.log")

local M = {}

--- Normalize a buffer's name for the store key.
---@param buf integer
---@return string|nil  nil when the buffer has no file behind it
function M.file_of(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    return vim.fs.normalize(name)
end

--- The VALID marks of a buffer, keyed by seq — each entry `{ tags = string[], checkpoints =
--- string[] }`. Validated against the live snapshot: a row whose seq is gone, or whose stored
--- `seq_time` no longer matches the live entry's time, is stale and skipped.
---@param buf integer
---@param snap LvimUndoSnapshot
---@return table<integer, { tags: string[], checkpoints: string[] }>
function M.for_buffer(buf, snap)
    local out = {}
    local file = M.file_of(buf)
    if not file then
        return out
    end
    for _, row in ipairs(store.for_file(file)) do
        local state = snap.all[row.seq]
        if state and (state.time or 0) == (row.seq_time or 0) then
            local slot = out[row.seq]
            if not slot then
                slot = { tags = {}, checkpoints = {} }
                out[row.seq] = slot
            end
            local list = row.kind == "checkpoint" and slot.checkpoints or slot.tags
            list[#list + 1] = row.name
        end
    end
    return out
end

--- Replace one state's tag set (empty `names` clears it). Fires the Tags event + logs.
---@param buf integer
---@param state LvimUndoState
---@param names string[]
---@return boolean ok
function M.set(buf, state, names)
    local file = M.file_of(buf)
    if not file then
        return false
    end
    store.set_tags(file, state.seq, state.time or 0, names)
    log.add(("tags of %s seq %d: %s"):format(vim.fn.fnamemodify(file, ":~:."), state.seq, table.concat(names, " ")))
    log.event("Tags", { file = file, seq = state.seq, tags = names })
    return true
end

--- Record a NAMED CHECKPOINT at the buffer's CURRENT undo state — the public `checkpoint(name)`
--- seam other lvim-* plugins (and the opt-in auto hooks) call. Fires the Checkpoint event + logs.
---@param buf integer
---@param name string
---@return boolean ok
function M.checkpoint(buf, name)
    local file = M.file_of(buf)
    if not file or vim.bo[buf].buftype ~= "" then
        return false
    end
    local ut = vim.fn.undotree(buf)
    local seq = ut.seq_cur or 0
    local seq_time = 0
    -- The live entry's own timestamp is the staleness guard the store keys on.
    local snap_entries = ut.entries or {}
    local function find_time(entries)
        for _, e in ipairs(entries) do
            if e.seq == seq then
                return e.time or 0
            end
            if e.alt then
                local t = find_time(e.alt)
                if t then
                    return t
                end
            end
        end
        return nil
    end
    seq_time = find_time(snap_entries) or 0
    store.add({ file = file, seq = seq, seq_time = seq_time, kind = "checkpoint", name = name })
    log.add(("checkpoint %q at %s seq %d"):format(name, vim.fn.fnamemodify(file, ":~:."), seq))
    log.event("Checkpoint", { file = file, seq = seq, name = name })
    return true
end

return M
