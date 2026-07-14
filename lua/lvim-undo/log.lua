-- lvim-undo.log: the session action log + the plugin's User autocmd bus.
-- Both live here because they are the same thing seen twice: every noteworthy action (a restore, a
-- purge, a tag write, a checkpoint) is RECORDED for `:LvimUndo log` and BROADCAST as a `User
-- LvimUndo<Event>` autocmd so a statusline / the control-center can react. Session-scoped by
-- design (the set's canon: session state stays in memory, never a DB).
--
---@module "lvim-undo.log"

local M = {}

---@type string[]  the session log, oldest first
local lines = {}

--- Record one timestamped line.
---@param msg string
function M.add(msg)
    lines[#lines + 1] = ("%s  %s"):format(os.date("%H:%M:%S"), msg)
end

--- The session log so far (oldest first).
---@return string[]
function M.list()
    return lines
end

--- Clear the session log.
function M.clear()
    lines = {}
end

--- Fire a `User LvimUndo<name>` autocmd with `data` (pcall-guarded: a listener error must never
--- break the action that fired it).
---@param name string  the event suffix ("Restore", "Step", "Purge", "Tags", "Checkpoint")
---@param data table?
function M.event(name, data)
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "LvimUndo" .. name, data = data or {} })
end

return M
