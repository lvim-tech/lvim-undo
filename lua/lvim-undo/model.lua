-- lvim-undo.model: the undo-tree model — a faithful graph over Neovim's own `undotree()`.
-- The undo history is NEVER shadowed: every snapshot re-reads `vim.fn.undotree(buf)` and converts
-- its nested `entries`/`alt` lists into linked state nodes (parent / next-in-chain / branches), so
-- the panel always renders what Neovim actually holds. The only thing the plugin stores itself is
-- METADATA (tags, checkpoint names) — the one thing Neovim has nowhere to put.
--
-- The non-obvious part is the `alt` shape: in `undotree().entries`, an entry's `alt` list is an
-- ALTERNATE branch that diverges at that entry's PARENT (the state before it in the chain), not at
-- the entry itself — so branches are attached to the previous node while walking. `next` links a
-- node to its successor IN THE SAME CHAIN (the redo direction), which is what the "current
-- timeline" view follows forward.
--
-- Text of an arbitrary state is read from a MIRROR buffer, never from the user's: `:wundo` writes the
-- source's undo tree to a temp file and `:rundo` loads it into a scratch buffer holding the same
-- text, so the whole tree can be walked there with `:undo <seq>`. Walking the REAL buffer works too
-- (and is what the obvious implementation does) but it EDITS it: `noautocmd` silences autocmds, yet
-- `on_bytes` still fires, so every scrub of the timeline sends the LSP a didChange storm (a heavy
-- server re-analyses the file on each one) and re-parses treesitter. The mirror is a nameless scratch
-- buffer — no client, no parser, no autocmds — so the source is never touched at all.
--
---@module "lvim-undo.model"

local M = {}

local api = vim.api

---@class LvimUndoState
---@field seq integer                the undo sequence number (0 = the origin, before the first change)
---@field time integer               epoch seconds of the change (0 for the origin)
---@field save integer|nil           the save number when the file was written at this state
---@field parent LvimUndoState|nil   the state this one was made from (nil on the origin)
---@field next LvimUndoState|nil     the successor in the SAME chain (the redo direction)
---@field branches LvimUndoState[][] alternate branches DIVERGING AT this state, each a chronological chain

---@class LvimUndoSnapshot
---@field root LvimUndoState             the origin (seq 0)
---@field main LvimUndoState[]           the top-level chain (the branch ending at seq_last), chronological
---@field all table<integer, LvimUndoState>  every state by seq
---@field seq_cur integer                the current position in the tree
---@field seq_last integer               the newest sequence number
---@field save_last integer              the newest save number
---@field total integer                  how many states exist (excluding the origin)

--- Convert one `entries` list (chronological) into linked state nodes, attaching each entry's
--- `alt` branches to the node BEFORE it (the fork point — see the module header).
---@param entries table[]                the undotree() entries (or an `alt` list)
---@param parent LvimUndoState           the state the first entry was made from
---@param all table<integer, LvimUndoState>  the by-seq registry (filled in place)
---@return LvimUndoState[] chain         the converted chain, chronological
local function link_chain(entries, parent, all)
    local chain = {}
    local prev = parent
    local prev_in_chain = nil
    for _, e in ipairs(entries) do
        if e.alt then
            -- The alternate branch diverges at `prev` (the state before this entry). Build it FIRST,
            -- append after: a NESTED alt (a branch that itself forks) recurses with the same `prev`
            -- and appends to `prev.branches` from inside the call — and Lua fixes the index of
            -- `prev.branches[#prev.branches + 1] = link_chain(…)` before running the right-hand side,
            -- so the outer assignment would overwrite the branch the inner one just added.
            local branch = link_chain(e.alt, prev, all)
            prev.branches[#prev.branches + 1] = branch
        end
        ---@type LvimUndoState
        local node = { seq = e.seq, time = e.time or 0, save = e.save, parent = prev, branches = {} }
        all[e.seq] = node
        chain[#chain + 1] = node
        if prev_in_chain then
            prev_in_chain.next = node
        end
        prev, prev_in_chain = node, node
    end
    return chain
end

--- Read the buffer's LIVE undo tree into a snapshot graph.
---@param buf integer
---@return LvimUndoSnapshot
function M.snapshot(buf)
    local ut = vim.fn.undotree(buf)
    ---@type LvimUndoState
    local root = { seq = 0, time = 0, parent = nil, branches = {} }
    local all = { [0] = root }
    local main = link_chain(ut.entries or {}, root, all)
    local total = 0
    for seq in pairs(all) do
        if seq > 0 then
            total = total + 1
        end
    end
    return {
        root = root,
        main = main,
        all = all,
        seq_cur = ut.seq_cur or 0,
        seq_last = ut.seq_last or 0,
        save_last = ut.save_last or 0,
        total = total,
    }
end

--- The set of seqs on the CURRENT timeline: the current state's ancestors (the undo direction) plus
--- its same-chain successors (the redo direction) — exactly the states plain `u`/`<C-r>` can reach.
---@param snap LvimUndoSnapshot
---@return table<integer, boolean>
function M.current_path(snap)
    local path = {}
    ---@type LvimUndoState|nil
    local node = snap.all[snap.seq_cur]
    while node do
        path[node.seq] = true
        node = node.parent
    end
    node = snap.all[snap.seq_cur]
    node = node and node.next
    while node do
        path[node.seq] = true
        node = node.next
    end
    return path
end

-- ─── time formatting ──────────────────────────────────────────────────────────

--- Compact relative age: "8s" / "5m" / "3h" / "2d".
---@param t integer  epoch seconds of the state
---@return string
local function fmt_relative(t)
    local d = math.max(0, os.time() - t)
    if d < 60 then
        return ("%ds"):format(d)
    elseif d < 3600 then
        return ("%dm"):format(math.floor(d / 60))
    elseif d < 86400 then
        return ("%dh"):format(math.floor(d / 3600))
    end
    return ("%dd"):format(math.floor(d / 86400))
end

--- Human age: the clock for today, weekday + clock inside a week, date past it.
---@param t integer
---@return string
local function fmt_pretty(t)
    local now = os.time()
    if os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d", now) then
        return tostring(os.date("%H:%M", t))
    elseif now - t < 7 * 86400 then
        return tostring(os.date("%a %H:%M", t))
    end
    return tostring(os.date("%d %b %Y", t))
end

--- Format a state's age per `format` ("relative" | "pretty" | "absolute").
---@param t integer          epoch seconds (0 = the origin: renders empty)
---@param format string
---@param absolute_format string  the os.date() pattern for "absolute"
---@return string
function M.fmt_time(t, format, absolute_format)
    if not t or t == 0 then
        return ""
    end
    if format == "absolute" then
        return tostring(os.date(absolute_format, t))
    elseif format == "pretty" then
        return fmt_pretty(t)
    end
    return fmt_relative(t)
end

-- ─── state text (the undo walk) ───────────────────────────────────────────────

---@class LvimUndoMirror
---@field buf integer      the scratch buffer carrying a copy of the source's undo tree
---@field tick integer     the source's `changedtick` when the mirror was built

---@type table<integer, LvimUndoMirror>  source buffer → its mirror
local mirrors = {}

--- Build (or rebuild) the mirror of `buf`: a nameless scratch buffer holding the source's current
--- text plus its whole undo tree, transferred with `:wundo` → `:rundo` (the tree is a file format,
--- and this is the mechanism Vim provides for moving it). `rundo` only accepts a buffer whose text
--- matches the one the tree was written from, so the copy must happen before anything else.
---@param buf integer
---@return integer|nil mirror buffer
local function build_mirror(buf)
    local file = vim.fn.tempname()
    local ok = pcall(api.nvim_buf_call, buf, function()
        vim.cmd("silent wundo! " .. vim.fn.fnameescape(file))
    end)
    if not ok or vim.fn.filereadable(file) == 0 then
        return nil
    end
    local mirror = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(mirror, 0, -1, false, api.nvim_buf_get_lines(buf, 0, -1, false))
    local loaded = pcall(api.nvim_buf_call, mirror, function()
        vim.cmd("silent rundo " .. vim.fn.fnameescape(file)) -- REPLACES the scratch's own one-change tree
    end)
    pcall(vim.fn.delete, file)
    if not loaded then
        pcall(api.nvim_buf_delete, mirror, { force = true })
        return nil
    end
    return mirror
end

--- The mirror for `buf`, rebuilt whenever the source has changed since it was made.
---@param buf integer
---@return integer|nil
local function mirror_of(buf)
    local tick = api.nvim_buf_get_changedtick(buf)
    local m = mirrors[buf]
    if m and api.nvim_buf_is_valid(m.buf) and m.tick == tick then
        return m.buf
    end
    if m and api.nvim_buf_is_valid(m.buf) then
        pcall(api.nvim_buf_delete, m.buf, { force = true })
    end
    mirrors[buf] = nil
    local mb = build_mirror(buf)
    if mb then
        mirrors[buf] = { buf = mb, tick = tick }
    end
    return mb
end

--- Drop a source buffer's mirror (called when the panel closes).
---@param buf integer|nil  nil = every mirror
function M.release(buf)
    for b, m in pairs(mirrors) do
        if buf == nil or b == buf then
            if api.nvim_buf_is_valid(m.buf) then
                pcall(api.nvim_buf_delete, m.buf, { force = true })
            end
            mirrors[b] = nil
        end
    end
end

--- The lines of the buffer at each of `seqs`, walked in the MIRROR (see the module header): jump to
--- each state with `:undo <seq>` there and read the lines. The user's buffer is never edited, so no
--- LSP didChange, no treesitter re-parse and no TextChanged chain fires while the timeline is
--- scrubbed. Requires a modifiable source (its undo tree is what gets copied — the caller guards).
---@param buf integer
---@param seqs integer[]
---@return table<integer, string[]>  seq → lines (missing seqs are skipped)
function M.texts_at(buf, seqs)
    local out = {}
    if not (buf and api.nvim_buf_is_valid(buf)) or not vim.bo[buf].modifiable then
        return out
    end
    local mirror = mirror_of(buf)
    if not mirror then
        return out
    end
    api.nvim_buf_call(mirror, function()
        for _, seq in ipairs(seqs) do
            if out[seq] == nil then
                if pcall(vim.cmd, ("silent undo %d"):format(seq)) then
                    out[seq] = api.nvim_buf_get_lines(mirror, 0, -1, false)
                end
            end
        end
    end)
    return out
end

--- The lines of the buffer at ONE state (see `texts_at`).
---@param buf integer
---@param seq integer
---@return string[]|nil
function M.text_at(buf, seq)
    return M.texts_at(buf, { seq })[seq]
end

return M
