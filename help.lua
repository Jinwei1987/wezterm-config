-- ==========================================================================
--  help.lua — Searchable shortcut cheat sheet for WezTerm
--
--  Keybinding: CMD+SHIFT+/ (CMD+?)
--  Usage: require("help").apply_to_config(config)
-- ==========================================================================

local wezterm = require("wezterm")
local M = {}

-- All custom shortcuts defined across the config.
-- Keep this in sync when adding new keybindings.
local shortcuts = {
  -- Pane
  { keys = "CMD+D",              desc = "Split pane right" },
  { keys = "CMD+SHIFT+D",        desc = "Split pane down" },
  { keys = "CTRL+SHIFT+Arrow",   desc = "Navigate between panes" },
  { keys = "ALT+SHIFT+Arrow",    desc = "Resize current pane" },
  { keys = "CMD+SHIFT+Enter",    desc = "Zoom / unzoom pane" },
  { keys = "CMD+W",              desc = "Close current pane" },
  { keys = "CMD+SHIFT+R",        desc = "Rotate panes" },

  -- Tab
  { keys = "CMD+T",              desc = "New tab" },
  { keys = "CMD+1…9",            desc = "Jump to tab by number" },
  { keys = "CMD+SHIFT+]",        desc = "Next tab" },
  { keys = "CMD+SHIFT+[",        desc = "Previous tab" },

  -- Copy / Search
  { keys = "CMD+SHIFT+C",        desc = "Enter copy mode (visual select)" },
  { keys = "CMD+F",              desc = "Search scrollback" },
  { keys = "CMD+SHIFT+F",        desc = "Quick select (links, hashes, IPs)" },

  -- Utility
  { keys = "CMD+K",              desc = "Clear scrollback" },
  { keys = "CMD+SHIFT+P",        desc = "Command palette" },
  { keys = "CMD+SHIFT+L",        desc = "Reload configuration" },
  { keys = "CMD+SHIFT+E",        desc = "Edit config in $EDITOR" },
  { keys = "CMD+=  /  CMD+-",    desc = "Font size up / down" },
  { keys = "CMD+0",              desc = "Reset font size" },

  -- OTP
  { keys = "CMD+SHIFT+J",        desc = "Auto-fill OTP (runs settings.otp_command)" },

  -- AI
  { keys = "CMD+SHIFT+N",        desc = "AI command bar (describe → command)" },
  { keys = "CMD+SHIFT+I",        desc = "AI suggest fix (select output first)" },
  { keys = "CMD+SHIFT+X",        desc = "AI explain output (select output first)" },
  { keys = "CMD+SHIFT+G",        desc = "AI git commit message" },

  -- Launchers
  { keys = "CMD+SHIFT+S",        desc = "Snippet launcher (fuzzy search)" },
  { keys = "CMD+SHIFT+Z",        desc = "Manage user snippets (add / delete)" },
  { keys = "CMD+SHIFT+H",        desc = "Host launcher (SSH/SFTP → tab or split)" },
  { keys = "CMD+SHIFT+M",        desc = "This help — search all shortcuts" },
}

-- Captured in apply_to_config so find_action can walk config.keys at runtime
-- to find the registered action matching a shortcut id like "CMD+SHIFT+N".
local stored_config

local function normalize_key(k)
  if #k == 1 then return k:lower() end
  return k
end

local MOD_ORDER = { CMD = 1, CTRL = 2, ALT = 3, SHIFT = 4, SUPER = 1 }

local function normalize_mods(list)
  table.sort(list, function(a, b)
    return (MOD_ORDER[a] or 99) < (MOD_ORDER[b] or 99)
  end)
  return table.concat(list, "|")
end

local function parse_shortcut(id)
  local parts = {}
  for p in id:gmatch("[^+]+") do table.insert(parts, p) end
  if #parts < 2 then return nil end
  local key = normalize_key(parts[#parts])
  local mods = {}
  for i = 1, #parts - 1 do table.insert(mods, parts[i]:upper()) end
  return key, normalize_mods(mods)
end

local function find_action(id)
  if not stored_config or not stored_config.keys then return nil end
  local target_key, target_mods = parse_shortcut(id)
  if not target_key then return nil end
  for _, entry in ipairs(stored_config.keys) do
    if entry.key and entry.mods then
      local ek = normalize_key(entry.key)
      local elist = {}
      for m in entry.mods:gmatch("[^|]+") do table.insert(elist, m:upper()) end
      if ek == target_key and normalize_mods(elist) == target_mods then
        return entry.action
      end
    end
  end
  return nil
end

local function show_help(window, pane)
  local choices = {}
  for _, s in ipairs(shortcuts) do
    table.insert(choices, {
      id = s.keys,
      label = string.format("%-22s  %s", s.keys, s.desc),
    })
  end

  window:perform_action(
    wezterm.action.InputSelector({
      title = "  Keyboard Shortcuts  (Enter: execute  ·  Esc: cancel)",
      choices = choices,
      fuzzy = true,
      fuzzy_description = "Type to search shortcuts:",
      action = wezterm.action_callback(function(inner_window, inner_pane, id, _)
        if not id then return end
        local action = find_action(id)
        if action then
          inner_window:perform_action(action, inner_pane)
        end
      end),
    }),
    pane
  )
end

function M.apply_to_config(config)
  stored_config = config
  config.keys = config.keys or {}

  -- CMD+SHIFT+/ (CMD+?) → show shortcut help
  table.insert(config.keys, {
    key = "m",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(show_help, window, pane)
      if not ok then
        wezterm.log_error("Help error: " .. tostring(err))
      end
    end),
  })
end

return M
