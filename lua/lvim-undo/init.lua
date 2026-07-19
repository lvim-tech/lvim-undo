-- lvim-undo: a navigable, branching undo-history TIMELINE for the lvim-tech set.
-- Every undo state is a row in a foldable graph (the panel — `lvim-ui.tabs` + `lvim-ui.tree` with
-- a live diff preview beside it): walk it, scrub the diff, restore any state (across branches),
-- tag the ones worth remembering (persisted in the plugin's own sqlite store), inspect an old
-- state in a scratch buffer / diffsplit, and list recent checkpoints across the whole project.
-- This module is the PUBLIC seam: `setup()`, the `:LvimUndo` command (one verb, subcommands +
-- layout tokens), the `checkpoint(name)` API other lvim-* plugins call, and the opt-in automatic
-- checkpoints (before format / LSP rename / a build event).
--
-- `User` autocmds fired (see lvim-undo.log): LvimUndoCheckpoint, LvimUndoRestore, LvimUndoStep,
-- LvimUndoPurge, LvimUndoTags — so a statusline / the control-center can react.
--
---@module "lvim-undo"

local api = vim.api
local config = require("lvim-undo.config")
local panel = require("lvim-undo.panel")
local store = require("lvim-undo.store")
local tags = require("lvim-undo.tags")
local log = require("lvim-undo.log")
local merge = require("lvim-utils.utils").merge
local hl = require("lvim-utils.highlight")
local highlights = require("lvim-undo.highlights")

local M = {}

---@type boolean  setup() ran (command + autocmds registered)
local registered = false

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-undo: " .. msg, level or vim.log.levels.INFO)
end

-- ── public API ───────────────────────────────────────────────────────────────

--- Open the timeline panel for the current buffer.
---@param opts LvimUndoOpenOpts?  per-open layout override + initial tab (see lvim-undo.panel)
function M.open(opts)
    panel.open(opts)
end

--- Close the panel.
function M.close()
    panel.close()
end

--- Toggle the panel.
---@param opts LvimUndoOpenOpts?
function M.toggle(opts)
    panel.toggle(opts)
end

--- Record a NAMED CHECKPOINT at a buffer's current undo state — the seam other lvim-* plugins
--- (and the opt-in auto hooks) call before an operation worth remembering. The name lands as a
--- badge on that state in the timeline and as a row in the project view; it survives restarts
--- through the plugin's own store (subject to `persist.tags`).
---@param name string
---@param opts? { buf?: integer }
---@return boolean ok
function M.checkpoint(name, opts)
    if type(name) ~= "string" or vim.trim(name) == "" then
        return false
    end
    local buf = (opts and opts.buf) or api.nvim_get_current_buf()
    return tags.checkpoint(buf, vim.trim(name))
end

--- Purge the CURRENT buffer's undo history (undofile + in-memory tree + stored marks).
---@param force boolean?  skip the confirmation (the `!` bang)
function M.purge(force)
    local buf = api.nvim_get_current_buf()
    local function run()
        local ok, msg = store.purge_buffer(buf)
        if ok then
            -- msg is a caveat note on a partial purge (nonmodifiable buffer), nil on a full purge
            notify(msg or "undo history purged", msg and vim.log.levels.WARN or nil)
            panel.refresh()
        else
            notify(msg or "purge failed", vim.log.levels.WARN)
        end
    end
    if force then
        run()
        return
    end
    require("lvim-ui").confirm({
        prompt = " " .. config.titles.purge,
        default_no = true,
        callback = function(yes)
            if yes then
                run()
            end
        end,
    })
end

--- Purge ALL undofiles + every stored mark.
---@param force boolean?  skip the confirmation (the `!` bang)
function M.purge_all(force)
    local function run()
        local removed = store.purge_all()
        notify(("%d undofile(s) purged"):format(removed))
        panel.refresh()
    end
    if force then
        run()
        return
    end
    require("lvim-ui").confirm({
        prompt = " " .. config.titles.purge_all,
        default_no = true,
        callback = function(yes)
            if yes then
                run()
            end
        end,
    })
end

--- Show the session action log in the canonical read-only viewer.
function M.show_log()
    local lines = log.list()
    if #lines == 0 then
        lines = { config.labels.log_empty }
    end
    require("lvim-ui").info(lines, { title = config.titles.log, hide_cursor = true })
end

--- Clear the session action log.
function M.clear_log()
    log.clear()
    notify("log cleared")
end

-- ── the opt-in automatic checkpoints ─────────────────────────────────────────

--- Install the enabled auto-checkpoint hooks (once, from setup): a named checkpoint lands on the
--- buffer's current state right BEFORE the operation, so "the version before the rename" is one
--- tagged row in the timeline. format / lsp_rename wrap the core `vim.lsp.buf` entry points (the
--- only seam Neovim offers — there is no pre-format/pre-rename autocmd); `build` listens on the
--- configured User event.
local function install_auto()
    local auto = config.checkpoints.auto
    local labels = config.checkpoints.labels
    if auto.format then
        local orig = vim.lsp.buf.format
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.lsp.buf.format = function(...)
            -- vim.lsp.buf.format({ bufnr = X }) can format a buffer OTHER than the current one (e.g. a
            -- format-on-save loop): checkpoint that exact buffer, not whichever happens to be current.
            local o = select(1, ...)
            M.checkpoint(labels.format, { buf = type(o) == "table" and o.bufnr or nil })
            return orig(...)
        end
    end
    if auto.lsp_rename then
        local orig = vim.lsp.buf.rename
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.lsp.buf.rename = function(...)
            M.checkpoint(labels.lsp_rename)
            return orig(...)
        end
    end
    if auto.build then
        api.nvim_create_autocmd("User", {
            pattern = config.checkpoints.build_event,
            group = api.nvim_create_augroup("LvimUndoAutoCheckpoint", { clear = true }),
            callback = function()
                M.checkpoint(labels.build)
            end,
            desc = "lvim-undo: checkpoint before a build action",
        })
    end
end

-- ── the command ──────────────────────────────────────────────────────────────

---@type table<string, boolean>
local LAYOUTS = { float = true, area = true, bottom = true }
local SUBS = { "toggle", "open", "close", "project", "purge", "purge-all", "log", "log-clear", "checkpoint" }

--- Parse `:LvimUndo` args: a layout token anywhere + a subcommand; `checkpoint` consumes the REST
--- as the checkpoint name (names may contain spaces).
---@param args string
---@return string sub, string? layout, string rest
local function parse(args)
    local sub, layout = "", nil
    local rest = {}
    for tok in args:gmatch("%S+") do
        if sub == "checkpoint" then
            rest[#rest + 1] = tok
        elseif LAYOUTS[tok] then
            layout = tok
        elseif sub == "" then
            sub = tok
        else
            rest[#rest + 1] = tok
        end
    end
    return sub, layout, table.concat(rest, " ")
end

--- Configure lvim-undo: merge `opts` into the live config, bind the theme factory, install the
--- persistence filter + auto-checkpoint hooks and register the `:LvimUndo` command. Idempotent
--- past the first call.
---@param opts LvimUndoConfig?
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true
    hl.setup()
    hl.bind(highlights.build)
    store.setup_filter()
    install_auto()

    api.nvim_create_user_command("LvimUndo", function(cmd)
        local sub, layout, rest = parse(cmd.args)
        if sub == "" or sub == "toggle" then
            M.toggle({ layout = layout })
        elseif sub == "open" then
            M.open({ layout = layout })
        elseif sub == "close" then
            M.close()
        elseif sub == "project" then
            M.open({ layout = layout, tab = "project" })
        elseif sub == "purge" then
            M.purge(cmd.bang)
        elseif sub == "purge-all" then
            M.purge_all(cmd.bang)
        elseif sub == "log" then
            M.show_log()
        elseif sub == "log-clear" then
            M.clear_log()
        elseif sub == "checkpoint" then
            if rest == "" then
                notify("checkpoint needs a name", vim.log.levels.WARN)
            elseif M.checkpoint(rest) then
                notify(("checkpoint %q recorded"):format(rest))
            else
                notify("checkpoint failed (not a file buffer?)", vim.log.levels.WARN)
            end
        else
            notify(("unknown subcommand '%s'"):format(sub), vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        bang = true,
        desc = "lvim-undo: [toggle] / open / close / project / purge[!] / purge-all[!] / log / log-clear / checkpoint <name> [float|area|bottom]",
        complete = function()
            local out = vim.list_extend({}, SUBS)
            return vim.list_extend(out, { "float", "area", "bottom" })
        end,
    })
end

return M
