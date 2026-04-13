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
  { keys = "CMD+SHIFT+H",        desc = "Host launcher (SSH/SFTP → tab or split)" },
  { keys = "CMD+SHIFT+M",        desc = "This help — search all shortcuts" },
}

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
      title = "  Keyboard Shortcuts",
      choices = choices,
      fuzzy = true,
      fuzzy_description = "Type to search shortcuts:",
      action = wezterm.action_callback(function(_, _, _, _)
        -- No-op: just a reference, selecting does nothing
      end),
    }),
    pane
  )
end

function M.apply_to_config(config)
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
