-- ==========================================================================
--  hosts.lua — SSH/SFTP Host Launcher for WezTerm
--
--  Reads ~/.ssh/config and provides a fuzzy picker to connect
--  via SSH or SFTP in a new tab. Tracks connections for tab titles.
--
--  Keybinding: CMD+SHIFT+H
--  Usage: require("hosts").apply_to_config(config)
-- ==========================================================================

local wezterm = require("wezterm")
local state = require("state")
local M = {}

-- ── Parse SSH Config ─────────────────────────────────────────────────────

local function parse_ssh_hosts()
  local home = os.getenv("HOME") or ""
  local f = io.open(home .. "/.ssh/config", "r")
  if not f then return {} end

  local hosts = {}
  local current = nil

  for line in f:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and #trimmed > 0 and not trimmed:match("^#") then
      local host_part = trimmed:match("^[Hh]ost%s+(.+)$")
      local is_host = host_part and not trimmed:match("^%s*[Hh]ost[A-Za-z]")
      if is_host then
        for alias in host_part:gmatch("%S+") do
          if not alias:match("[%*%?]") then
            current = { name = alias, hostname = nil, user = nil, port = nil }
            table.insert(hosts, current)
          end
        end
      end
      if current then
        local hn = trimmed:match("^%s*[Hh]ost[Nn]ame%s+(%S+)")
        if hn then current.hostname = hn end
        local u = trimmed:match("^%s*[Uu]ser%s+(%S+)")
        if u then current.user = u end
        local p = trimmed:match("^%s*[Pp]ort%s+(%d+)")
        if p then current.port = p end
      end
    end
  end
  f:close()
  return hosts
end

-- ── Host Launcher ────────────────────────────────────────────────────────

local function host_launcher(window, pane)
  local hosts = parse_ssh_hosts()
  if #hosts == 0 then
    -- Show a message in a new tab
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if f then
      f:write("No hosts found in ~/.ssh/config\n\nPress q to close.\n")
      f:close()
    end
    window:perform_action(
      wezterm.action.SpawnCommandInNewTab({
        args = { "/bin/zsh", "-c", string.format("less '%s'; rm -f '%s'", tmp, tmp) },
      }),
      pane
    )
    return
  end

  -- Build choices: each host gets an SSH and SFTP entry
  local choices = {}
  for _, h in ipairs(hosts) do
    local display_info = h.hostname and ("  →  " .. h.hostname) or ""
    if h.port and h.port ~= "22" then
      display_info = display_info .. ":" .. h.port
    end

    table.insert(choices, {
      id = "ssh:" .. h.name,
      label = "SSH   " .. h.name .. display_info,
    })
    table.insert(choices, {
      id = "sftp:" .. h.name,
      label = "SFTP  " .. h.name .. display_info,
    })
  end

  window:perform_action(
    wezterm.action.InputSelector({
      title = "  Host Launcher — SSH / SFTP",
      choices = choices,
      fuzzy = true,
      fuzzy_description = "Type to search hosts:",
      action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
        if not id then return end
        local proto, name = id:match("^(%w+):(.+)$")
        if not proto then return end

        local cmd
        if proto == "ssh" then
          cmd = "ssh " .. name
        else
          cmd = "sftp " .. name
        end

        -- Ask: new tab or split pane?
        inner_window:perform_action(
          wezterm.action.InputSelector({
            title = "  Open " .. proto:upper() .. " → " .. name,
            choices = {
              { id = "tab", label = "New Tab" },
              { id = "right", label = "Split Right (vertical)" },
              { id = "bottom", label = "Split Down (horizontal)" },
            },
            fuzzy = false,
            action = wezterm.action_callback(function(win, p, open_id)
              if not open_id then return end

              local spawn_args = { "/bin/zsh", "-l", "-c", cmd }

              local function track(new_pane)
                if new_pane then
                  state.pane_connections[tostring(new_pane:pane_id())] = {
                    proto = proto,
                    host = name,
                  }
                end
              end

              if open_id == "tab" then
                win:perform_action(
                  wezterm.action_callback(function(w, _)
                    local tab, new_pane, _ = w:mux_window():spawn_tab({
                      args = spawn_args,
                    })
                    track(new_pane)
                  end),
                  p
                )
              else
                local direction = open_id == "right" and "Right" or "Bottom"
                win:perform_action(
                  wezterm.action_callback(function(w, cur_pane)
                    local new_pane = cur_pane:split({
                      direction = direction,
                      args = spawn_args,
                    })
                    track(new_pane)
                  end),
                  p
                )
              end
            end),
          }),
          inner_pane
        )
      end),
    }),
    pane
  )
end

-- ── Apply to Config ──────────────────────────────────────────────────────

function M.apply_to_config(config)
  config.keys = config.keys or {}

  -- CMD+SHIFT+H → Host Launcher (SSH/SFTP picker from ~/.ssh/config)
  table.insert(config.keys, {
    key = "h",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(host_launcher, window, pane)
      if not ok then
        wezterm.log_error("Host launcher error: " .. tostring(err))
      end
    end),
  })
end

return M
