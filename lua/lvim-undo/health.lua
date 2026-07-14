-- lvim-undo.health: :checkhealth lvim-undo.
-- Diagnoses the things that make an undo timeline silently useless: is persistent undo actually
-- ON and is 'undodir' writable (else nothing survives a restart), which external diff engines are
-- really on PATH (else the preview quietly falls back to native), how large the undodir has grown
-- (the purge commands exist for a reason), which persistence backend the tag store opened, and —
-- the headline — the exclusion VERDICT for the CURRENT buffer, answering "why is nothing being
-- remembered here?". Read-only reporting; nothing is mutated.
--
---@module "lvim-undo.health"

local config = require("lvim-undo.config")
local store = require("lvim-undo.store")

local M = {}

--- Total size + file count of every 'undodir' directory.
---@return integer files, integer bytes
local function undodir_usage()
    local files, bytes = 0, 0
    for dir in tostring(vim.o.undodir):gmatch("[^,]+") do
        dir = vim.fs.normalize(dir)
        if vim.fn.isdirectory(dir) == 1 then
            for name, kind in vim.fs.dir(dir) do
                if kind == "file" then
                    files = files + 1
                    bytes = bytes + math.max(0, vim.fn.getfsize(dir .. "/" .. name))
                end
            end
        end
    end
    return files, bytes
end

--- Human byte count.
---@param n integer
---@return string
local function fmt_bytes(n)
    if n < 1024 then
        return ("%d B"):format(n)
    elseif n < 1024 * 1024 then
        return ("%.1f KiB"):format(n / 1024)
    end
    return ("%.1f MiB"):format(n / (1024 * 1024))
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-undo")

    if vim.fn.has("nvim-0.12") == 1 then
        health.ok("Neovim >= 0.12 (vim.text.diff, undotree(buf))")
    else
        health.error("Neovim >= 0.12 is required (vim.text.diff, undotree(buf))")
    end

    local ok_ui = pcall(require, "lvim-ui")
    local ok_utils = pcall(require, "lvim-utils.highlight")
    if ok_ui and ok_utils then
        health.ok("lvim-ui + lvim-utils found (the panel chassis + theming)")
    else
        health.error("lvim-ui / lvim-utils not found — the panel cannot open")
    end

    -- Persistent undo: without it the timeline only covers the session.
    if vim.o.undofile then
        health.ok("'undofile' is on — histories persist across restarts")
    else
        health.warn("'undofile' is off — undo histories are session-only (set vim.o.undofile = true)")
    end
    local writable = false
    for dir in tostring(vim.o.undodir):gmatch("[^,]+") do
        dir = vim.fs.normalize(dir)
        if vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) == 2 then
            writable = true
            break
        end
    end
    if writable then
        local files, bytes = undodir_usage()
        health.ok(
            ("'undodir' is writable — %d undofile(s), %s (purge with :LvimUndo purge-all)"):format(
                files,
                fmt_bytes(bytes)
            )
        )
    else
        health.error("no writable directory in 'undodir' — undofiles cannot be written")
    end

    -- External diff engines: report what the configured one and the others actually resolve to.
    for _, tool in ipairs({ "delta", "difft", "diff" }) do
        local configured = config.diff.engine == tool
        if vim.fn.executable(tool) == 1 then
            health.ok(("%s found%s"):format(tool, configured and " (the configured engine)" or ""))
        elseif configured then
            health.warn(("diff.engine = %q but it is not on PATH — the preview falls back to native"):format(tool))
        else
            health.info(("%s not found (optional external engine)"):format(tool))
        end
    end
    if config.diff.engine == "native" then
        health.ok("diff.engine = native (vim.text.diff — no external process)")
    end

    -- The tag/checkpoint store.
    local ok_store, ustore = pcall(require, "lvim-utils.store")
    if ok_store then
        ustore.health(health, false)
    end
    if not config.persist.tags then
        health.info("persist.tags = false — tags and checkpoints are session-only by choice")
    elseif store.persistent() then
        health.ok("tag store: sqlite (own db under stdpath('data')/lvim-undo/)")
    else
        health.warn("persist.tags = true but sqlite.lua is unavailable — tags are session-only")
    end

    -- The verdict for the CURRENT buffer — "why is nothing being remembered here?".
    local buf = vim.api.nvim_get_current_buf()
    local reason = store.exclusion_reason(buf)
    if reason then
        health.info(("current buffer gets NO persistent undo: %s"):format(reason))
    else
        health.ok("current buffer passes the persistence filter")
    end
end

return M
