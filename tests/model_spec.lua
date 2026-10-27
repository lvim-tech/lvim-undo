-- The undo graph, read from Neovim's own tree, and read without touching the buffer.
--
-- Two things carry this plugin. First the shape: in `undotree().entries` an entry's `alt` list is
-- a branch that diverges at that entry's PARENT, not at the entry itself, so a branch has to be
-- attached to the node BEFORE the one carrying it. Get that wrong and the tree renders with its
-- forks one state too late, which is the kind of thing nobody notices by reading.
--
-- Second, and the reason the mirror buffer exists at all: reading the text of an arbitrary state
-- must not edit the user's buffer. Walking the real one works and is what the obvious
-- implementation does, but `on_bytes` still fires under `noautocmd`, so every scrub of the
-- timeline sends an LSP didChange storm. So: after reading every state, the source's changedtick,
-- its undo tree and its text must all be exactly as they were.

local model = require("lvim-undo.model")
local store = require("lvim-undo.store")
local config = require("lvim-undo.config")

--- Replace the buffer's text and CLOSE the undo block, so the change is a state of its own.
--- Without the block break every write lands in the same undo entry and there is no history at all.
---@param buf integer
---@param text string
local function commit(buf, text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    vim.cmd("let &undolevels = &undolevels")
end

--- A FRESH buffer whose undo history is `steps`, one state per step.
---@param steps string[]
---@return integer buf
local function history(steps)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    for _, text in ipairs(steps) do
        commit(buf, text)
    end
    return buf
end

describe("lvim-undo: the graph")

it("a linear history is one chain, parent to child", function()
    local buf = history({ "A", "AB", "ABC" })
    local snap = model.snapshot(buf)

    eq(3, snap.total)
    eq(3, snap.seq_last)
    eq(3, snap.seq_cur)
    eq(3, #snap.main)
    eq(0, snap.root.seq)

    for seq = 1, 3 do
        eq(seq - 1, snap.all[seq].parent.seq, "state " .. seq .. " was made from the one before it")
    end
    for seq = 1, 2 do
        eq(seq + 1, snap.all[seq].next.seq, "and redo goes forward along the same chain")
    end
    eq(nil, snap.all[3].next)
    eq({}, snap.all[2].branches, "a linear history has no forks")
    model.release(buf)
end)

it("a branch is attached to the state it diverges FROM", function()
    -- A, AB, ABC, then two undos back to A, then AX, AXY: the branch {AB, ABC} forks at A.
    local buf = history({ "A", "AB", "ABC" })
    vim.cmd("silent undo")
    vim.cmd("silent undo")
    commit(buf, "AX")
    commit(buf, "AXY")

    local snap = model.snapshot(buf)
    eq(5, snap.total)
    eq(5, snap.seq_cur)

    local fork = snap.all[1]
    eq(1, #fork.branches, "the fork is at seq 1, the state both chains were made from")
    eq(
        { 2, 3 },
        vim.tbl_map(function(n)
            return n.seq
        end, fork.branches[1]),
        "the abandoned chain, chronological"
    )
    eq(0, #snap.all[4].branches, "and NOT at seq 4, whose `alt` list carried it in undotree()")
    eq(1, snap.all[4].parent.seq)
    model.release(buf)
end)

it("the current timeline is what plain u and CTRL-R can reach", function()
    local buf = history({ "A", "AB", "ABC" })
    vim.cmd("silent undo")
    vim.cmd("silent undo")
    commit(buf, "AX")
    commit(buf, "AXY")

    local snap = model.snapshot(buf)
    local path = model.current_path(snap)
    local on = {}
    for seq in pairs(path) do
        on[#on + 1] = seq
    end
    table.sort(on)

    eq({ 0, 1, 4, 5 }, on, "the ancestors and the same-chain successors; the abandoned branch is not reachable")
    eq(nil, path[2])
    eq(nil, path[3])
    model.release(buf)
end)

it("an empty history is just the origin", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    local snap = model.snapshot(buf)
    eq(0, snap.total)
    eq(0, snap.seq_cur)
    eq(0, #snap.main)
    eq(0, snap.root.seq)
end)

describe("lvim-undo: the text of a state")

it("every state's text is readable", function()
    local buf = history({ "A", "AB", "ABC" })
    local texts = model.texts_at(buf, { 0, 1, 2, 3 })
    eq({ "" }, texts[0], "the origin is the buffer before the first change")
    eq({ "A" }, texts[1])
    eq({ "AB" }, texts[2])
    eq({ "ABC" }, texts[3])
    model.release(buf)
end)

it("text from a branch is readable too, without going there", function()
    local buf = history({ "A", "AB", "ABC" })
    vim.cmd("silent undo")
    vim.cmd("silent undo")
    commit(buf, "AX")

    eq({ "ABC" }, model.text_at(buf, 3), "a state on the abandoned branch")
    eq({ "AX" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "and the buffer is still where the user left it")
    model.release(buf)
end)

it("reading the whole timeline leaves the source buffer untouched", function()
    local buf = history({ "A", "AB", "ABC" })
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local tree = vim.inspect(vim.fn.undotree(buf))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    model.texts_at(buf, { 0, 1, 2, 3 })

    eq(tick, vim.api.nvim_buf_get_changedtick(buf), "an edit here is an LSP didChange the user never made")
    eq(tree, vim.inspect(vim.fn.undotree(buf)), "and the history itself must not move")
    eq(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    model.release(buf)
end)

it("a seq that does not exist has no text", function()
    local buf = history({ "A" })
    eq(nil, model.text_at(buf, 99))
    model.release(buf)
end)

describe("lvim-undo: how a state's age reads")

it("the origin has no age at all", function()
    eq("", model.fmt_time(0, "relative", "%c"))
    eq("", model.fmt_time(nil, "pretty", "%c"))
end)

it("relative is the compact age", function()
    local now = os.time()
    eq("5s", model.fmt_time(now - 5, "relative", ""))
    eq("59s", model.fmt_time(now - 59, "relative", ""))
    eq("1m", model.fmt_time(now - 60, "relative", ""))
    eq("5m", model.fmt_time(now - 300, "relative", ""))
    eq("1h", model.fmt_time(now - 3600, "relative", ""))
    eq("2h", model.fmt_time(now - 7200, "relative", ""))
    eq("1d", model.fmt_time(now - 86400, "relative", ""))
    eq("3d", model.fmt_time(now - 3 * 86400, "relative", ""))
end)

it("a state in the future does not read as a negative age", function()
    eq("0s", model.fmt_time(os.time() + 600, "relative", ""), "a clock change must not print -600s")
end)

it("absolute uses the configured pattern", function()
    local now = os.time()
    eq(tostring(os.date("%Y", now)), model.fmt_time(now, "absolute", "%Y"))
end)

it("pretty is the clock today and the date further back", function()
    local now = os.time()
    eq(tostring(os.date("%H:%M", now)), model.fmt_time(now, "pretty", ""))
    local long_ago = now - 30 * 86400
    eq(tostring(os.date("%d %b %Y", long_ago)), model.fmt_time(long_ago, "pretty", ""))
end)

describe("lvim-undo: which buffers get persistent undo")

--- A buffer with the given options, named so a size check has something to look at.
---@param opts table
---@return integer
local function buffer_with(opts)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    for k, v in pairs(opts) do
        vim.bo[buf][k] = v
    end
    return buf
end

it("chrome never has persistent undo", function()
    local buf = buffer_with({ buftype = "nofile" })
    local why = store.exclusion_reason(buf)
    truthy(why, "a nofile buffer is not content")
    truthy(why:match("buftype"), why)
end)

it("an excluded filetype is named as the reason", function()
    local was = config.persist.exclude_filetypes
    config.persist.exclude_filetypes = { "lvim-undo-spec-ft" }
    local buf = buffer_with({ filetype = "lvim-undo-spec-ft" })
    local why = store.exclusion_reason(buf)
    config.persist.exclude_filetypes = was

    truthy(why, "the exclusion list has to be honoured")
    truthy(why:match("filetype"), why)
end)

it("an ordinary buffer is not excluded", function()
    local buf = buffer_with({ filetype = "lua" })
    eq(nil, store.exclusion_reason(buf))
end)

it("a file over the size limit is excluded, by its real size", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/big.txt"
    local lines = {}
    for i = 1, 200 do
        lines[i] = ("x"):rep(100)
    end
    vim.fn.writefile(lines, path)

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    local was = config.persist.max_file_size

    config.persist.max_file_size = 1000
    local why = store.exclusion_reason(buf)
    truthy(why, "a 20 kB file against a 1 kB limit")
    truthy(why:match("size"), why)

    config.persist.max_file_size = 10 * 1024 * 1024
    eq(nil, store.exclusion_reason(buf), "and the same file is fine under a bigger limit")

    config.persist.max_file_size = was
    vim.cmd("bwipeout!")
end)

describe("lvim-undo: tags survive, stale rows do not")

it("the tag set of a state is replaced whole, and an empty set clears it", function()
    local file = vim.fn.tempname() .. "/tagged.txt"
    local seq, seq_time = 7, 1700000000

    store.set_tags(file, seq, seq_time, { "alpha", "beta" })
    local names = {}
    for _, m in ipairs(store.for_file(file)) do
        if m.kind == "tag" then
            names[#names + 1] = m.name
        end
    end
    table.sort(names)
    eq({ "alpha", "beta" }, names)

    store.set_tags(file, seq, seq_time, { "only" })
    local after = {}
    for _, m in ipairs(store.for_file(file)) do
        if m.kind == "tag" then
            after[#after + 1] = m.name
        end
    end
    eq({ "only" }, after, "the editor writes the whole set at once")

    store.set_tags(file, seq, seq_time, {})
    local cleared = {}
    for _, m in ipairs(store.for_file(file)) do
        if m.kind == "tag" then
            cleared[#cleared + 1] = m.name
        end
    end
    eq({}, cleared)
    store.drop_file(file)
end)

it("a mark carries the entry's own timestamp, which is what makes a stale one detectable", function()
    local file = vim.fn.tempname() .. "/stamped.txt"
    store.set_tags(file, 3, 1700000000, { "pinned" })
    local rows = store.for_file(file)
    truthy(#rows >= 1)
    local mark = rows[1]
    eq(3, mark.seq)
    eq(1700000000, mark.seq_time, "a purged undofile renumbers its states; the time is the guard")
    eq("tag", mark.kind)
    store.drop_file(file)
    eq({}, store.for_file(file))
end)
