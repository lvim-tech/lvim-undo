-- lvim-undo.highlights: every group the panel paints with, built from the LIVE lvim-utils palette
-- and the plugin's `config.colors` roles. `build()` is registered through `lvim-utils.highlight
-- .bind` in setup(), so the groups re-derive on ColorScheme / palette sync and track the theme.
-- Accents are palette KEYS (never a hex in code); tint strengths are ROLE NAMES resolved against
-- the shared `lvim-utils.config.ui` scale — the plugin defines no numeric scale of its own.
--
---@module "lvim-undo.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-undo.config")

local M = {}

--- The shared tint scale (`lvim-utils.config.ui` `tint`), read LIVE so a retuned scale reaches us.
---@return table<string, number>
local function shared_tints()
    local ok, ui = pcall(require, "lvim-utils.config.ui")
    return (ok and type(ui) == "table" and ui.tint) or {}
end

--- Resolve a config accent: a palette key (tracks the live theme) or a literal "#rrggbb".
---@param key string
---@return string
local function accent(key)
    local v = c[key]
    return type(v) == "string" and v or key
end

--- Resolve a tint value: a ROLE name from the shared scale, or a raw factor.
---@param t string|number|nil
---@param tints table<string, number>
---@return number|nil
local function tint_of(t, tints)
    if type(t) == "number" then
        return t
    end
    if type(t) == "string" then
        return tints[t]
    end
    return nil
end

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param color string
---@param t number
---@return string
local function mtint(color, t)
    return hl.blend(color, c.bg, t)
end

--- The lvim-undo highlight groups from the live palette + `config.colors`.
---@return table<string, table>
function M.build()
    local col = config.colors
    local tints = shared_tints()

    --- fg-only group from a colour role.
    ---@param role LvimUndoColor
    ---@return table
    local function fg(role)
        return { fg = accent(role.accent) }
    end
    --- badge group (accent fg on its own soft tint) from a colour role.
    ---@param role LvimUndoColor
    ---@param bold boolean?
    ---@return table
    local function badge(role, bold)
        local a = accent(role.accent)
        local t = tint_of(role.tint, tints)
        return { fg = a, bg = t and mtint(a, t) or nil, bold = bold or nil }
    end

    local help = col.help
    local odd, even = accent(help.odd), accent(help.even)
    local kt = tint_of(help.key_tint, tints) or 0
    local dt = tint_of(help.desc_tint, tints) or 0

    return {
        -- timeline rows
        LvimUndoCurrent = badge(col.current, true), -- the ➤ current-state marker + its seq
        LvimUndoSeq = fg(col.state), -- a state's sequence number
        LvimUndoTime = fg(col.time), -- the dim age cell
        LvimUndoSaved = fg(col.saved), -- the saved-state icon
        LvimUndoTagBadge = badge(col.tag), -- a tag badge box
        LvimUndoCheckpointBadge = badge(col.checkpoint), -- a named-checkpoint badge box
        LvimUndoFile = fg(col.file), -- a project row's file name
        LvimUndoEmpty = { fg = accent(col.empty.accent), italic = true },
        LvimUndoHeader = badge(col.filter), -- the panel header band (file ➤ view ➤ filter)

        -- the native diff preview
        LvimUndoAdded = fg(col.added),
        LvimUndoRemoved = fg(col.removed),
        LvimUndoHunk = { fg = accent(col.hunk.accent), bold = true },
        LvimUndoContext = fg(col.context),

        -- the help window (the striping canon: odd blue / even yellow, key box above the desc box;
        -- the ACTIVE row's description rises to the key tint so the row reads as one solid block)
        LvimUndoHelpKeyOdd = { fg = odd, bg = mtint(odd, kt), bold = true },
        LvimUndoHelpDescOdd = { fg = odd, bg = mtint(odd, dt) },
        LvimUndoHelpDescActiveOdd = { fg = odd, bg = mtint(odd, kt) },
        LvimUndoHelpKeyEven = { fg = even, bg = mtint(even, kt), bold = true },
        LvimUndoHelpDescEven = { fg = even, bg = mtint(even, dt) },
        LvimUndoHelpDescActiveEven = { fg = even, bg = mtint(even, kt) },
    }
end

return M
