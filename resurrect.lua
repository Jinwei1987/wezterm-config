-- ==========================================================================
--  resurrect.lua — Session & pane layout persistence
--
--  Thin wrapper around the resurrect.wezterm plugin:
--    https://github.com/MLFlexer/resurrect.wezterm
--
--  Behavior:
--    • Periodic save every 5 minutes (workspaces + windows)
--    • Save on window-focus-changed (debounced by plugin)
--    • Auto-restore the "default" workspace on GUI startup
--    • CMD+SHIFT+B → save the current session now (toast confirms)
--    • CMD+SHIFT+Y → fuzzy picker to restore any saved state
--
--  State files live under the plugin's own install dir:
--    ~/Library/Application Support/wezterm/plugins/
--      httpssCssZssZsgithubsDscomsZsMLFlexersZsresurrectsDswezterm/state/
--      ├── workspace/   (e.g. default.json)
--      ├── window/
--      └── tab/
--  (macOS path; Linux uses $XDG_DATA_HOME/wezterm/plugins/…)
--
--  Caveats (inherent to resurrect, not this wrapper):
--    • Running processes are re-spawned from their launch command, not
--      resumed. Shell history inside a pane is NOT restored.
--    • SSH panes re-run `ssh <host>` — relies on your ssh-agent / keys.
--    • Scrollback is re-inserted as static text (not live output).
--
--  Usage: require("resurrect").apply_to_config(config)
-- ==========================================================================

local wezterm = require("wezterm")
local M = {}

-- The plugin fetches from GitHub on first load; wrap in pcall so a network
-- blip or API drift can't take down the rest of the config.
--
-- We point at our fork, which carries a fix for a null-pane crash in
-- upstream's `pane_tree.lua:78` (`insert_panes` pushes the same
-- PaneInformation into both right and bottom buckets when a pane is
-- diagonally past the root's bottom-right corner; the right-branch pass
-- nulls `.pane` and the bottom-branch pass then derefs nil). Upstream:
-- https://github.com/MLFlexer/resurrect.wezterm
local load_ok, resurrect = pcall(function()
  return wezterm.plugin.require("https://github.com/Jinwei1987/resurrect.wezterm")
end)
if not load_ok or not resurrect then
  wezterm.log_error("resurrect.wezterm plugin failed to load: " .. tostring(resurrect))
  resurrect = nil
end

M.plugin = resurrect

-- Wrap plugin calls in pcall — its API is unstable across versions, so if
-- any entrypoint renames we degrade gracefully instead of crashing.
local function safe(fn, ...)
  if not fn then return nil end
  local ok, res = pcall(fn, ...)
  if not ok then
    wezterm.log_error("resurrect call failed: " .. tostring(res))
    return nil
  end
  return res
end

-- Resolve a dotted path on the plugin table without erroring on missing
-- intermediates. Needed because expressions like `resurrect.state_manager.x`
-- evaluate before `safe()` can catch them — if `state_manager` is gone after
-- an API change, the whole config load aborts at that line.
local function resolve(...)
  local cur = resurrect
  for _, key in ipairs({ ... }) do
    if type(cur) ~= "table" then return nil end
    cur = cur[key]
  end
  return cur
end

function M.apply_to_config(config)
  if not resurrect then return end
  config.keys = config.keys or {}

  -- ── Periodic auto-save ─────────────────────────────────────────
  -- Runs on the plugin's internal timer; no extra code needed from us.
  safe(resolve("state_manager", "periodic_save"), {
    interval_seconds = 5 * 60,
    save_workspaces = true,
    save_windows = true,
    save_tabs = false,
  })

  -- ── Save on focus change ───────────────────────────────────────
  wezterm.on("window-focus-changed", function(_, _)
    local state = safe(resolve("workspace_state", "get_workspace_state"))
    if state then safe(resolve("state_manager", "save_state"), state) end
  end)

  -- ── Auto-restore on GUI startup ────────────────────────────────
  -- If a "default" workspace snapshot exists, restore it into the first
  -- spawned window. Otherwise WezTerm opens its normal default window.
  -- Note: `gui-startup` only fires once per wezterm process — reloading
  -- the config with CMD+SHIFT+L does NOT re-trigger this path. To test a
  -- restore, fully quit WezTerm and relaunch (or use CMD+SHIFT+Y).
  wezterm.on("gui-startup", function(cmd)
    local mux = wezterm.mux
    local _tab, _pane, window = mux.spawn_window(cmd or {})

    local state = safe(resolve("state_manager", "load_state"), "default", "workspace")
    if state and next(state) and window and state.window_states then
      safe(resolve("workspace_state", "restore_workspace"), state, {
        window = window,
        relative = true,
        restore_text = true,
        on_pane_restore = resolve("tab_state", "default_on_pane_restore"),
      })
    end
  end)

  -- ── CMD+SHIFT+B → save current session under a given name ─────
  -- Prompts for a name, then saves the current workspace state to
  -- `state/workspace/<name>.json`. Empty input cancels. The plugin's
  -- save_state(state, opt_name) uses opt_name as the filename override,
  -- so you can keep multiple named snapshots side-by-side with `default`.
  table.insert(config.keys, {
    key = "b",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local state = safe(resolve("workspace_state", "get_workspace_state"))
      if not state then
        window:toast_notification("WezTerm", "Session save failed (no state)", nil, 3000)
        return
      end
      local default_name = state.workspace or "default"
      window:perform_action(
        wezterm.action.PromptInputLine({
          description = wezterm.format({
            { Attribute = { Intensity = "Bold" } },
            { Foreground = { Color = "#a6e3a1" } },
            { Text = "  Save session as  (empty = '" .. default_name
              .. "'  ·  Esc: cancel):" },
          }),
          action = wezterm.action_callback(function(w, _, name)
            if name == nil then return end  -- Esc pressed
            -- Empty input → use the current workspace name as the filename.
            if #name == 0 then name = default_name end
            -- Sanitize: strip path separators so the user can't escape the
            -- state dir, and drop any trailing .json since the plugin adds it.
            name = name:gsub("[/\\]", "_"):gsub("%.json$", "")
            if #name == 0 then return end
            -- save_state returns nothing on success, so check pcall status
            -- directly rather than the (always-nil) return value.
            local save_fn = resolve("state_manager", "save_state")
            if not save_fn then
              w:toast_notification("WezTerm", "Session save unavailable — plugin API drift", nil, 3000)
              return
            end
            local ok, err = pcall(save_fn, state, name)
            if ok then
              w:toast_notification("WezTerm", "Session saved: " .. name, nil, 2500)
            else
              wezterm.log_error("resurrect save_state failed: " .. tostring(err))
              w:toast_notification("WezTerm", "Session save failed — check wezterm.log", nil, 3000)
            end
          end),
        }),
        pane
      )
    end),
  })

  -- ── CMD+SHIFT+Y → fuzzy-load a saved state ─────────────────────
  -- fuzzy_loader returns ids like "<type><sep><name>.json" (e.g.
  -- "workspace/default.json"). The plugin's load_state appends ".json"
  -- itself, so we must strip it or it double-appends and 404s.
  table.insert(config.keys, {
    key = "y",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local fuzzy_load = resolve("fuzzy_loader", "fuzzy_load")
      if not fuzzy_load then
        wezterm.log_error("resurrect.fuzzy_loader unavailable — plugin API may have changed")
        return
      end
      fuzzy_load(window, pane, function(id, _)
        if not id then return end
        local kind, name = id:match("^([^/\\]+)[/\\](.+)$")
        if not kind then kind, name = "workspace", id end
        name = name:gsub("%.json$", "")
        local state = safe(resolve("state_manager", "load_state"), name, kind)
        if not state or not next(state) then
          window:toast_notification("WezTerm", "Failed to load " .. kind .. "/" .. name, nil, 3000)
          return
        end
        local restore_fn
        if kind == "workspace" then
          restore_fn = resolve("workspace_state", "restore_workspace")
        elseif kind == "window" then
          restore_fn = resolve("window_state", "restore_window")
        elseif kind == "tab" then
          restore_fn = resolve("tab_state", "restore_tab")
        end
        if not restore_fn then
          wezterm.log_error("resurrect: no restore fn for kind=" .. tostring(kind))
          return
        end
        -- Plugin signatures differ by kind:
        --   restore_workspace(state, opts)
        --   restore_window(mux_window, state, opts)
        --   restore_tab(mux_tab, state, opts)
        local opts = {
          window = window:mux_window(),
          relative = true,
          restore_text = true,
          on_pane_restore = resolve("tab_state", "default_on_pane_restore"),
        }
        if kind == "workspace" then
          safe(restore_fn, state, opts)
        elseif kind == "window" then
          safe(restore_fn, window:mux_window(), state, opts)
        elseif kind == "tab" then
          safe(restore_fn, window:mux_window():active_tab(), state, opts)
        end
      end)
    end),
  })
end

return M
