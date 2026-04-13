-- ==========================================================================
--  ai.lua — AI features for WezTerm (Claude + GPT support)
--
--  Features:
--    1. AI Command Suggest  (CMD+SHIFT+I) — get suggested fix from output
--    2. AI Explain Output   (CMD+SHIFT+X) — explain errors/logs
--    3. AI Git Commit Msg   (CMD+SHIFT+G) — generate commit message
--
--  Setup:
--    Add one or both API keys to ~/.config/wezterm/settings.lua:
--      return {
--        anthropic = "sk-ant-...",
--        openai    = "sk-...",
--      }
--    (Env vars ANTHROPIC_API_KEY / OPENAI_API_KEY are also honored as a fallback,
--    but WezTerm's Lua does NOT inherit shell rc exports, so settings.lua is preferred.)
--
--  Usage: require("ai").apply_to_config(config)
-- ==========================================================================

local wezterm = require("wezterm")
local M = {}

-- ── Configuration ────────────────────────────────────────────────────────

M.default_provider = "claude"

M.models = {
  claude = "claude-sonnet-4-20250514",
  gpt = "gpt-4o",
}

-- ── Helpers ──────────────────────────────────────────────────────────────

-- Load API keys from settings.lua, env vars, or shell (in that order)
local _settings = {}
local _settings_loaded = false

local function load_settings()
  if _settings_loaded then return end
  _settings_loaded = true

  -- 1. Try settings.lua file (most reliable)
  local ok, file_settings = pcall(require, "settings")
  if ok and type(file_settings) == "table" then
    _settings.anthropic = file_settings.anthropic
    _settings.openai = file_settings.openai
  end

  -- 2. Try os.getenv as fallback
  if not _settings.anthropic then
    local v = os.getenv("ANTHROPIC_API_KEY")
    if v and #v > 0 then _settings.anthropic = v end
  end
  if not _settings.openai then
    local v = os.getenv("OPENAI_API_KEY")
    if v and #v > 0 then _settings.openai = v end
  end
end

local function get_api_key(provider)
  load_settings()
  if provider == "claude" then
    return _settings.anthropic
  elseif provider == "gpt" then
    return _settings.openai
  end
  return nil
end

local function pick_provider()
  local pref = M.default_provider
  if get_api_key(pref) then return pref end
  local other = pref == "claude" and "gpt" or "claude"
  if get_api_key(other) then return other end
  return nil
end

local NO_KEY_MSG = [[No API key found!

Add your key to ~/.config/wezterm/settings.lua:

    return {
      openai = "sk-...",
      -- anthropic = "sk-ant-...",
    }

Then save the file — WezTerm auto-reloads.]]

-- Write text to a temp file, return path
local function write_tmp(text)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if f then
    f:write(text)
    f:close()
  end
  return tmp
end

-- Build the curl command, writing payload to a temp file to avoid shell escaping issues
local function call_ai(system_prompt, user_message)
  local provider = pick_provider()
  if not provider then
    return nil, NO_KEY_MSG
  end

  local api_key = get_api_key(provider)

  -- Build JSON payload and write to temp file to avoid all shell escaping pain
  local payload, url, headers
  if provider == "claude" then
    url = "https://api.anthropic.com/v1/messages"
    -- Escape for JSON
    local sys = system_prompt:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
    local usr = user_message:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
    payload = '{"model":"' .. M.models.claude .. '","max_tokens":1024,'
      .. '"system":"' .. sys .. '",'
      .. '"messages":[{"role":"user","content":"' .. usr .. '"}]}'
    headers = string.format(
      "-H 'Content-Type: application/json' -H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01'",
      api_key
    )
  else
    url = "https://api.openai.com/v1/chat/completions"
    local sys = system_prompt:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
    local usr = user_message:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
    payload = '{"model":"' .. M.models.gpt .. '","max_tokens":1024,'
      .. '"messages":[{"role":"system","content":"' .. sys .. '"},'
      .. '{"role":"user","content":"' .. usr .. '"}]}'
    headers = string.format(
      "-H 'Content-Type: application/json' -H 'Authorization: Bearer %s'",
      api_key
    )
  end

  local payload_file = write_tmp(payload)
  local cmd = string.format("curl -s -X POST '%s' %s -d @'%s' 2>/dev/null; rm -f '%s'",
    url, headers, payload_file, payload_file)

  local handle = io.popen(cmd)
  if not handle then
    return nil, "Failed to execute curl"
  end
  local body = handle:read("*a")
  handle:close()

  if not body or #body == 0 then
    return nil, "Empty response from API"
  end

  -- Parse response
  local text
  if provider == "claude" then
    text = body:match('"text"%s*:%s*"(.-)"')
  else
    text = body:match('"content"%s*:%s*"(.-)"')
  end

  if text then
    return text:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\t", "\t"), nil
  end

  -- Check for error message in response
  local api_err = body:match('"message"%s*:%s*"(.-)"')
  if api_err then
    return nil, "API error: " .. api_err
  end

  return nil, "Could not parse API response:\n" .. body:sub(1, 300)
end

-- Show result: write to temp file, open a new tab with less
local function show_result(window, title, text)
  local content = "━━━ " .. title .. " ━━━\n\n" .. text .. "\n\n━━━ Press q to close ━━━\n"
  local tmp = write_tmp(content)
  window:perform_action(
    wezterm.action.SpawnCommandInNewTab({
      args = { "/bin/zsh", "-c", string.format("less -R '%s'; rm -f '%s'", tmp, tmp) },
    }),
    window:active_pane()
  )
end

-- Get selected text: copy selection to clipboard, then read it
-- This is the most reliable cross-version way in WezTerm
local function get_selection(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if sel and #sel:gsub("%s+", "") > 0 then
    return sel
  end
  return nil
end

-- ── Feature 1: AI Command Suggest ────────────────────────────────────────

local function ai_command_suggest(window, pane)
  local context = get_selection(window, pane)
  if not context then
    show_result(window, "AI Command Suggest",
      "No text selected.\n\nHow to use:\n  1. Select some terminal output (click+drag or enter Copy Mode)\n  2. Press CMD+SHIFT+I")
    return
  end

  show_result(window, "AI Command Suggest", "Thinking... (this tab will update)")

  local response, err = call_ai(
    "You are a terminal command expert. The user shows terminal output (possibly errors). "
    .. "Suggest the best command(s) to fix it. Reply ONLY with commands, one per line. "
    .. "If multiple steps, number them. No markdown fences.",
    context
  )

  if err then
    show_result(window, "AI Error", err)
  else
    show_result(window, "AI Suggested Commands", response)
  end
end

-- ── Feature 2: AI Explain Output ─────────────────────────────────────────

local function ai_explain_output(window, pane)
  local context = get_selection(window, pane)
  if not context then
    show_result(window, "AI Explain",
      "No text selected.\n\nHow to use:\n  1. Select some terminal output (click+drag or enter Copy Mode)\n  2. Press CMD+SHIFT+X")
    return
  end

  local response, err = call_ai(
    "You are a helpful terminal assistant. Explain the following terminal output in plain English. "
    .. "Be concise but thorough. If there are errors, explain the cause and how to fix them. "
    .. "Format for easy terminal reading, no markdown.",
    context
  )

  if err then
    show_result(window, "AI Error", err)
  else
    show_result(window, "AI Explanation", response)
  end
end

-- ── Feature 3: AI Git Commit Message ─────────────────────────────────────

local function ai_git_commit(window, pane)
  -- Try to get cwd from the pane
  local cwd = "."
  local pane_cwd = pane:get_current_working_dir()
  if pane_cwd then
    -- WezTerm returns a URL object; extract the file path
    local path = pane_cwd.file_path or tostring(pane_cwd):match("file://[^/]*(/.+)")
    if path then cwd = path end
  end

  -- Get staged diff
  local handle = io.popen(string.format("cd '%s' && git diff --cached 2>/dev/null", cwd))
  local diff = ""
  if handle then
    diff = handle:read("*a")
    handle:close()
  end

  -- Fallback to unstaged
  if #diff:gsub("%s+", "") == 0 then
    handle = io.popen(string.format("cd '%s' && git diff 2>/dev/null", cwd))
    if handle then
      diff = handle:read("*a")
      handle:close()
    end
  end

  if #diff:gsub("%s+", "") == 0 then
    show_result(window, "AI Git Commit", "No git changes found (staged or unstaged).")
    return
  end

  -- Truncate large diffs
  if #diff > 8000 then
    diff = diff:sub(1, 8000) .. "\n... (truncated)"
  end

  local response, err = call_ai(
    "You are a git commit message expert. Given a git diff, write a conventional commit message. "
    .. "Format: type(scope): description. Types: feat, fix, refactor, docs, style, test, chore. "
    .. "Subject under 72 chars. Add brief body only if complex. Reply ONLY with the message.",
    diff
  )

  if err then
    show_result(window, "AI Error", err)
    return
  end

  -- Type the commit command into the original pane
  local first_line = response:match("^([^\n]+)")
  if first_line then
    pane:send_text('git commit -m "' .. first_line:gsub('"', '\\"') .. '"')
  end
end

-- ── Feature 4: AI Command Bar (natural language → shell command) ──────────

local function ai_command_bar(window, pane)
  -- Use WezTerm's built-in input prompt
  window:perform_action(
    wezterm.action.PromptInputLine({
      description = wezterm.format({
        { Attribute = { Intensity = "Bold" } },
        { Foreground = { Color = "#f9e2af" } },
        { Text = "  AI Command Bar — describe what you want to do:" },
      }),
      action = wezterm.action_callback(function(inner_window, inner_pane, line)
        if not line or #line == 0 then return end

        -- Get OS info for context
        local os_info = ""
        local h = io.popen("uname -s 2>/dev/null")
        if h then os_info = h:read("*a"):gsub("%s+$", ""); h:close() end

        local response, err = call_ai(
          "You are a shell command generator. The user describes what they want in plain English. "
          .. "Generate the exact shell command(s) to accomplish it. "
          .. "OS: " .. os_info .. ". Shell: zsh. "
          .. "Reply ONLY with the command. No explanation, no markdown, no code fences. "
          .. "If multiple commands are needed, join them with && on one line.",
          line
        )

        if err then
          show_result(inner_window, "AI Error", err)
          return
        end

        if response then
          -- Clean up: take only the first meaningful line
          local cmd = response:gsub("^%s+", ""):gsub("%s+$", "")
          -- Paste the command but don't execute (user presses Enter to confirm)
          inner_pane:send_text(cmd)
        end
      end),
    }),
    pane
  )
end

-- ── Feature 5: Snippet Launcher (fuzzy-pick saved commands) ──────────────

local function snippet_launcher(window, pane)
  -- Load snippets
  local snippets_ok, snippets = pcall(require, "snippets")
  if not snippets_ok or not snippets then
    show_result(window, "Snippets", "Could not load snippets.lua\nCreate it at ~/.config/wezterm/snippets.lua")
    return
  end

  -- Build choices for InputSelector
  local choices = {}
  for _, s in ipairs(snippets) do
    table.insert(choices, {
      id = s.command,
      label = s.label .. (s.desc and ("  —  " .. s.desc) or ""),
    })
  end

  window:perform_action(
    wezterm.action.InputSelector({
      title = "  Snippet Launcher — select a command",
      choices = choices,
      fuzzy = true,
      fuzzy_description = "Type to search snippets:",
      action = wezterm.action_callback(function(_, inner_pane, id, label)
        if id then
          -- Paste the command but don't execute (user presses Enter)
          inner_pane:send_text(id)
        end
      end),
    }),
    pane
  )
end

-- ── Apply to Config ──────────────────────────────────────────────────────

function M.apply_to_config(config)
  config.keys = config.keys or {}

  -- CMD+SHIFT+I → AI Command Suggest
  table.insert(config.keys, {
    key = "i",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(ai_command_suggest, window, pane)
      if not ok then
        wezterm.log_error("AI suggest error: " .. tostring(err))
      end
    end),
  })

  -- CMD+SHIFT+X → AI Explain Output
  table.insert(config.keys, {
    key = "x",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(ai_explain_output, window, pane)
      if not ok then
        wezterm.log_error("AI explain error: " .. tostring(err))
      end
    end),
  })

  -- CMD+SHIFT+G → AI Git Commit Message
  table.insert(config.keys, {
    key = "g",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(ai_git_commit, window, pane)
      if not ok then
        wezterm.log_error("AI git commit error: " .. tostring(err))
      end
    end),
  })

  -- CMD+SHIFT+N → AI Command Bar (type what you want, AI generates the command)
  table.insert(config.keys, {
    key = "n",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(ai_command_bar, window, pane)
      if not ok then
        wezterm.log_error("AI command bar error: " .. tostring(err))
      end
    end),
  })

  -- CMD+SHIFT+S → Snippet Launcher (fuzzy search saved commands)
  table.insert(config.keys, {
    key = "s",
    mods = "CMD|SHIFT",
    action = wezterm.action_callback(function(window, pane)
      local ok, err = pcall(snippet_launcher, window, pane)
      if not ok then
        wezterm.log_error("Snippet launcher error: " .. tostring(err))
      end
    end),
  })

end

return M
