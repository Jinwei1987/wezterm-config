-- ==========================================================================
--  WezTerm Configuration — Best Practices Starter Config
--  Place this file at: ~/.wezterm.lua
--  Or at: ~/.config/wezterm/wezterm.lua
-- ==========================================================================

local wezterm = require("wezterm")
local act = wezterm.action
local state_ok, state = pcall(require, "state")
if not state_ok then state = { pane_connections = {} } end
local ai_ok, ai = pcall(require, "ai")
if not ai_ok then
  wezterm.log_error("Failed to load ai.lua: " .. tostring(ai))
  ai = nil
end
local hosts_ok, hosts = pcall(require, "hosts")
if not hosts_ok then
  wezterm.log_error("Failed to load hosts.lua: " .. tostring(hosts))
  hosts = nil
end
local help_ok, help = pcall(require, "help")
if not help_ok then
  wezterm.log_error("Failed to load help.lua: " .. tostring(help))
  help = nil
end
local settings_ok, settings = pcall(require, "settings")
if not settings_ok then settings = {} end

-- Use config_builder for clearer error messages on typos / bad values
local config = wezterm.config_builder()

-- ==========================================================================
--  1. APPEARANCE & THEME
-- ==========================================================================

-- Color scheme — pick one you like, or browse:
--   wezterm ls-colors  (CLI)
--   https://wezfurlong.org/wezterm/colorschemes/index.html
config.color_scheme = "Monokai Soda" -- high contrast, warm tones, easy on eyes

-- Window padding (pixels)
config.window_padding = {
  left = 8,
  right = 8,
  top = 8,
  bottom = 8,
}

-- Background opacity (1.0 = fully opaque)
config.window_background_opacity = 0.95
config.macos_window_background_blur = 20 -- macOS only: blur behind transparent window

-- Window decorations
config.window_decorations = "RESIZE" -- minimal: no title bar, keep resize handles
config.window_close_confirmation = "AlwaysPrompt"
config.initial_cols = 140
config.initial_rows = 40

-- ==========================================================================
--  2. FONT
-- ==========================================================================

-- Use a Nerd Font for icon/glyph support (powerline, devicons, etc.)
config.font = wezterm.font_with_fallback({
  {
    family = "JetBrains Mono",
    weight = "Medium",
    harfbuzz_features = { "calt=1", "clig=1", "liga=1" }, -- enable ligatures
  },
  { family = "Symbols Nerd Font Mono", scale = 0.9 },
  "Noto Color Emoji",
})
config.font_size = 14.0
config.line_height = 1.15 -- a touch of breathing room between lines
config.cell_width = 1.0

-- Disable the annoying font-size warning when a glyph isn't found
config.warn_about_missing_glyphs = false

-- ==========================================================================
--  3. CURSOR
-- ==========================================================================

config.default_cursor_style = "BlinkingBar"
config.cursor_blink_ease_in = "Constant"
config.cursor_blink_ease_out = "Constant"
config.cursor_blink_rate = 500 -- ms

-- ==========================================================================
--  4. TAB BAR
-- ==========================================================================

config.enable_tab_bar = true
config.use_fancy_tab_bar = false -- use the retro/minimal tab bar
config.tab_bar_at_bottom = false
config.hide_tab_bar_if_only_one_tab = true
config.show_tab_index_in_tab_bar = true
config.tab_max_width = 32
config.switch_to_last_active_tab_when_closing_tab = true

-- ── SSH hostname resolution ──────────────────────────────────────
-- Parse ~/.ssh/config to build lookup tables:
--   hostname_to_alias : HostName (IP/FQDN) → Host alias
--   alias_to_hostname : Host alias → HostName
--   jump_hosts        : Host alias → ProxyJump target alias
-- This handles direct connections, jump hosts, and chained proxies.
-- Maps any IP/host/user-string that might appear in pane title → Host alias
local ssh_lookup = {}

local function load_ssh_config()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. "/.ssh/config", "r")
  if not f then return end

  local current_aliases = {}
  local current_hostname = nil
  local current_user = nil

  local function flush_block()
    if #current_aliases > 0 then
      local alias = current_aliases[1] -- use the first alias as display name
      -- Map HostName → alias
      if current_hostname then
        ssh_lookup[current_hostname] = alias
      end
      if current_user then
        -- Map the full User string → alias  (e.g. "user@jumphost@10.0.0.1")
        ssh_lookup[current_user] = alias
        -- Extract every IP embedded in the User field and map each one
        for ip in current_user:gmatch("(%d+%.%d+%.%d+%.%d+)") do
          ssh_lookup[ip] = alias
        end
        -- Extract every user@host segment and map those too
        -- e.g. "user@jumphost@10.0.0.1" → also map "jumphost@10.0.0.1"
        local remainder = current_user
        while remainder:match("@") do
          remainder = remainder:match("@(.+)")
          if remainder then
            ssh_lookup[remainder] = alias
          end
        end
        -- Map "full_user@hostname" if HostName is set
        if current_hostname then
          ssh_lookup[current_user .. "@" .. current_hostname] = alias
        end
      end
    end
  end

  for line in f:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and #trimmed > 0 and not trimmed:match("^#") then
      -- Match "Host ..." but NOT "HostName ..." or "HostKeyAlgorithms ..." etc.
      local host_part = trimmed:match("^[Hh]ost%s+(.+)$")
      local is_host_directive = host_part and not trimmed:match("^%s*[Hh]ost[A-Za-z]")
      if is_host_directive then
        flush_block()
        current_aliases = {}
        current_hostname = nil
        current_user = nil
        for a in host_part:gmatch("%S+") do
          if not a:match("[%*%?]") then
            table.insert(current_aliases, a)
          end
        end
      end

      if #current_aliases > 0 then
        local hostname_val = trimmed:match("^%s*[Hh]ost[Nn]ame%s+(%S+)")
        if hostname_val then
          current_hostname = hostname_val
        end
        local user_val = trimmed:match("^%s*[Uu]ser%s+(%S+)")
        if user_val then
          current_user = user_val
        end
      end
    end
  end
  flush_block()
  f:close()
end

-- Load once at config parse time — wrapped in pcall so a bad ssh config
-- can never break the rest of wezterm.lua
local ok, err = pcall(load_ssh_config)
if not ok then
  wezterm.log_error("Failed to parse ~/.ssh/config: " .. tostring(err))
end

-- Resolve any string against the ssh_lookup table by trying progressively
-- shorter suffixes. E.g. for "user@jumphost@10.0.0.1":
--   try "user@jumphost@10.0.0.1"  → match!
--   or  "jumphost@10.0.0.1"       → match!
--   or  "10.0.0.1"                → match!
local function resolve_ssh(str)
  if not str then return nil end
  -- Try full string first
  if ssh_lookup[str] then return ssh_lookup[str] end
  -- Progressively strip leading user@ segments
  local remainder = str
  while remainder:match("@") do
    remainder = remainder:match("@(.+)")
    if remainder and ssh_lookup[remainder] then
      return ssh_lookup[remainder]
    end
  end
  -- Try every embedded IP
  for ip in str:gmatch("(%d+%.%d+%.%d+%.%d+)") do
    if ssh_lookup[ip] then return ssh_lookup[ip] end
  end
  return nil
end

-- Trim long names from the front: "region-app-env-role-NN" → "...env-role-NN"
local function trim_front(s, max)
  max = max or 20
  if not s or #s <= max then return s end
  return "..." .. s:sub(-(max - 3))
end

-- Custom tab title: show SSH hostname when connected, otherwise process + cwd
wezterm.on("format-tab-title", function(tab, _, _, _, _, _)
  local pane = tab.active_pane
  local title = pane.title
  local index = tab.tab_index + 1
  local pane_id = tostring(pane.pane_id)

  -- 1. Check tracked connections first (set by host launcher)
  local conn = state.pane_connections[pane_id]
  if conn then
    local icon = conn.proto == "sftp" and "📂" or "🖥"
    return string.format(" %d: %s %s ", index, icon, trim_front(conn.host))
  end

  -- 2. Detect SSH / SFTP sessions by process name OR pane title
  local foreground_process = pane.foreground_process_name or ""
  local is_ssh = foreground_process:match("ssh$")
  local is_sftp = foreground_process:match("sftp$")

  -- Also detect from title (handles cases where process is zsh wrapping ssh/sftp)
  if not is_ssh and not is_sftp then
    if title:match("^sftp%s") or title:match("^sftp>") or title:match("sftp%s+%S") then
      is_sftp = true
    elseif title:match("^ssh%s") or title:match("ssh%s+%S") then
      is_ssh = true
    end
  end

  if is_ssh or is_sftp then
    local icon = is_sftp and "📂" or "🖥"
    local user_host = title:match("(%S+@%S+)")
      or title:match("sftp%s+(%S+)")
      or title:match("ssh%s+(%S+)")
    if user_host then
      local display = resolve_ssh(user_host)
      if display then
        state.pane_connections[pane_id] = { proto = is_sftp and "sftp" or "ssh", host = display }
        return string.format(" %d: %s %s ", index, icon, trim_front(display))
      end
      local fallback = user_host:match("([^@]+)$") or user_host
      return string.format(" %d: %s %s ", index, icon, trim_front(fallback))
    end
    local alias = title:gsub("%s+$", ""):match("(%S+)$")
    if alias then
      local display = resolve_ssh(alias) or alias
      return string.format(" %d: %s %s ", index, icon, trim_front(display))
    end
  end

  -- Fallback: trim front for long titles
  return string.format(" %d: %s ", index, trim_front(title, 24))
end)

-- ==========================================================================
--  5. SCROLLBACK & HISTORY
-- ==========================================================================

config.scrollback_lines = 10000
config.enable_scroll_bar = false -- keep it minimal; use keyboard to scroll

-- ==========================================================================
--  6. GPU / RENDERING / PERFORMANCE
-- ==========================================================================

-- Use the GPU for rendering (best performance). Options:
--   "WebGpu" (preferred, modern), "OpenGL" (fallback), "Software" (CPU only)
config.front_end = "WebGpu"
config.webgpu_power_preference = "HighPerformance"

-- Reduce latency: push frames as soon as they are ready
config.max_fps = 120
config.animation_fps = 60

-- Disable IME on platforms where you don't need it (reduces input latency)
-- config.use_ime = false  -- uncomment if you don't use CJK input methods

-- ==========================================================================
--  7. SHELL INTEGRATION
-- ==========================================================================

-- Set default shell explicitly (optional — WezTerm auto-detects)
-- config.default_prog = { "/bin/zsh", "-l" }

-- For best shell integration add to your .zshrc / .bashrc:
--   source "$WEZTERM_EXECUTABLE_DIR/../Resources/shell-integration/wezterm.sh" 2>/dev/null
-- This enables: clickable paths, semantic zones, OSC 7 cwd tracking, etc.

-- ==========================================================================
--  8. KEYBINDINGS  — Direct Modifier Keys (no leader / no tmux)
-- ==========================================================================
--  Design: every shortcut is a single chord — no two-step leader sequence.
--  Uses CMD on macOS; swap CMD → ALT (or CTRL) on Linux/Windows below.
--  Pane navigation uses CTRL+SHIFT+Arrow so it never collides with shell
--  readline shortcuts (CTRL+A, CTRL+E, etc.).

config.keys = {
  -- ── Pane Splitting ──────────────────────────────────────────────
  -- CMD+D → split right    CMD+SHIFT+D → split down
  {
    key = "d",
    mods = "CMD",
    action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
  },
  {
    key = "d",
    mods = "CMD|SHIFT",
    action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
  },

  -- ── Pane Navigation (arrow keys — no vim knowledge needed) ─────
  { key = "LeftArrow",  mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Left") },
  { key = "RightArrow", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Right") },
  { key = "UpArrow",    mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Up") },
  { key = "DownArrow",  mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Down") },

  -- ── Pane Resizing (hold ALT+SHIFT+Arrow) ───────────────────────
  { key = "LeftArrow",  mods = "ALT|SHIFT", action = act.AdjustPaneSize({ "Left", 3 }) },
  { key = "RightArrow", mods = "ALT|SHIFT", action = act.AdjustPaneSize({ "Right", 3 }) },
  { key = "UpArrow",    mods = "ALT|SHIFT", action = act.AdjustPaneSize({ "Up", 3 }) },
  { key = "DownArrow",  mods = "ALT|SHIFT", action = act.AdjustPaneSize({ "Down", 3 }) },

  -- ── Pane Management ────────────────────────────────────────────
  -- CMD+SHIFT+Enter → toggle zoom (maximize/restore current pane)
  { key = "Enter", mods = "CMD|SHIFT", action = act.TogglePaneZoomState },
  -- CMD+W → close current pane (with confirmation)
  { key = "w", mods = "CMD", action = act.CloseCurrentPane({ confirm = true }) },
  -- CMD+SHIFT+R → rotate/swap panes
  { key = "r", mods = "CMD|SHIFT", action = act.RotatePanes("Clockwise") },

  -- ── Tab Management ─────────────────────────────────────────────
  -- CMD+T → new tab (matches browser convention)
  { key = "t", mods = "CMD", action = act.SpawnTab("CurrentPaneDomain") },
  -- CMD+SHIFT+] / [ → next / previous tab
  { key = "]", mods = "CMD|SHIFT", action = act.ActivateTabRelative(1) },
  { key = "[", mods = "CMD|SHIFT", action = act.ActivateTabRelative(-1) },
  -- CMD+1‥9 → jump to tab by number
  { key = "1", mods = "CMD", action = act.ActivateTab(0) },
  { key = "2", mods = "CMD", action = act.ActivateTab(1) },
  { key = "3", mods = "CMD", action = act.ActivateTab(2) },
  { key = "4", mods = "CMD", action = act.ActivateTab(3) },
  { key = "5", mods = "CMD", action = act.ActivateTab(4) },
  { key = "6", mods = "CMD", action = act.ActivateTab(5) },
  { key = "7", mods = "CMD", action = act.ActivateTab(6) },
  { key = "8", mods = "CMD", action = act.ActivateTab(7) },
  { key = "9", mods = "CMD", action = act.ActivateTab(8) },

  -- ── Copy / Search / Select ─────────────────────────────────────
  -- CMD+SHIFT+C → enter copy mode (visual selection in scrollback)
  { key = "c", mods = "CMD|SHIFT", action = act.ActivateCopyMode },
  -- CMD+F → search scrollback (like browser find)
  { key = "f", mods = "CMD", action = act.Search("CurrentSelectionOrEmptyString") },
  -- CMD+SHIFT+F → quick select (highlight links, hashes, IPs, etc.)
  { key = "f", mods = "CMD|SHIFT", action = act.QuickSelect },

  -- ── Utility ────────────────────────────────────────────────────
  -- CMD+K → clear scrollback + viewport
  { key = "k", mods = "CMD", action = act.ClearScrollback("ScrollbackAndViewport") },
  -- CMD+SHIFT+P → command palette (discover all actions)
  { key = "p", mods = "CMD|SHIFT", action = act.ActivateCommandPalette },
  -- CMD+SHIFT+L → reload configuration
  { key = "l", mods = "CMD|SHIFT", action = act.ReloadConfiguration },
  -- CMD+SHIFT+E → open config file in $EDITOR
  {
    key = "e",
    mods = "CMD|SHIFT",
    action = act.SpawnCommandInNewTab({
      args = { os.getenv("EDITOR") or "vi", wezterm.config_file },
    }),
  },

  -- ── Font Size ──────────────────────────────────────────────────
  -- CMD+= / CMD+- / CMD+0 → zoom in / out / reset  (built-in, listed for reference)
  { key = "=", mods = "CMD", action = act.IncreaseFontSize },
  { key = "-", mods = "CMD", action = act.DecreaseFontSize },
  { key = "0", mods = "CMD", action = act.ResetFontSize },

  -- ── MFA / OTP Auto-fill ────────────────────────────────────────
  -- CMD+SHIFT+J → run settings.otp_command, type its stdout into the active pane.
  -- Configure the command in ~/.config/wezterm/settings.lua as `otp_command`.
  {
    key = "j",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local cmd = settings.otp_command
      if not cmd or cmd == "" then
        local msg = table.concat({
          "━━━ WezTerm OTP ━━━",
          "",
          "otp_command is not set.",
          "",
          "Add the following to ~/.config/wezterm/settings.lua",
          "and reload with CMD+SHIFT+L:",
          "",
          '    otp_command = "/absolute/path/to/otp-cmd <args>",',
          "",
          "━━━ Press q to close ━━━",
          "",
        }, "\n")
        local tmp = os.tmpname()
        local f = io.open(tmp, "w")
        if f then f:write(msg); f:close() end
        window:perform_action(
          wezterm.action.SpawnCommandInNewTab({
            args = { "/bin/zsh", "-c", string.format("less -R '%s'; rm -f '%s'", tmp, tmp) },
          }),
          pane
        )
        return
      end
      local handle = io.popen(cmd .. " 2>/dev/null")
      if not handle then return end
      local otp = handle:read("*a")
      handle:close()
      if otp then
        otp = otp:gsub("%s+$", "")
        if #otp > 0 then
          pane:send_text(otp)
        end
      end
    end),
  },
}

-- ── Mouse Bindings ─────────────────────────────────────────────
config.mouse_bindings = {
  -- Ctrl+Click to open hyperlinks
  {
    event = { Up = { streak = 1, button = "Left" } },
    mods = "CTRL",
    action = act.OpenLinkAtMouseCursor,
  },
}

-- ==========================================================================
--  9. MULTIPLEXER DOMAINS (optional SSH/Unix)
-- ==========================================================================

-- Uncomment and customize if you want built-in SSH multiplexing:
-- config.ssh_domains = {
--   {
--     name = "my-server",
--     remote_address = "server.example.com",
--     username = "user",
--     multiplexing = "WezTerm",   -- run wezterm-mux-server on remote
--   },
-- }

-- Unix domain for local multiplexing (persist sessions after closing window):
-- config.unix_domains = {
--   { name = "unix" },
-- }
-- Then connect with: wezterm connect unix

-- ==========================================================================
--  10. MISC QUALITY OF LIFE
-- ==========================================================================

-- Reduce noise
config.audible_bell = "Disabled"
config.visual_bell = {
  fade_in_duration_ms = 75,
  fade_out_duration_ms = 75,
  target = "CursorColor",
}

-- URL detection: automatically highlight clickable URLs
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Quick select patterns (Leader+f): add common patterns
config.quick_select_patterns = {
  -- Match git short hashes (7+ hex chars)
  "[0-9a-f]{7,40}",
  -- Match UUIDs
  "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
  -- Match IP addresses
  "\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}",
}

-- Inactive pane dimming (helps visually distinguish focused pane)
config.inactive_pane_hsb = {
  saturation = 0.85,
  brightness = 0.7,
}

-- Don't prompt if only one pane is open
config.skip_close_confirmation_for_processes_named = {
  "bash",
  "sh",
  "zsh",
  "fish",
  "tmux",
  "nu",
  "cmd.exe",
  "pwsh.exe",
  "powershell.exe",
}

-- Status bar: show current workspace name
wezterm.on("update-right-status", function(window, _)
  local workspace = window:active_workspace()

  window:set_right_status(wezterm.format({
    { Foreground = { Color = "#a6adc8" } },
    { Text = " " .. workspace .. " " },
  }))
end)

-- ==========================================================================
--  Done! Return the config to WezTerm.
-- ==========================================================================

-- ==========================================================================
--  AI Features (CMD+SHIFT+A / CMD+SHIFT+X / CMD+SHIFT+G)
-- ==========================================================================
if ai then ai.apply_to_config(config) end
if hosts then hosts.apply_to_config(config) end
if help then help.apply_to_config(config) end

return config
