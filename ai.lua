-- ==========================================================================
--  ai.lua — AI features for WezTerm (Claude + GPT + Perplexity support)
--
--  Features:
--    1. AI Command Suggest  (CMD+SHIFT+I) — get suggested fix from output
--    2. AI Explain Output   (CMD+SHIFT+X) — explain errors/logs
--    3. AI Git Commit Msg   (CMD+SHIFT+G) — generate commit message
--    4. AI Chat             (CMD+SHIFT+N) — multi-turn AI conversation
--
--  Setup:
--    Add one or more API keys to ~/.config/wezterm/settings.lua:
--      return {
--        anthropic  = "sk-ant-...",
--        openai     = "sk-...",
--        perplexity = "pplx-...",
--      }
--    (Env vars ANTHROPIC_API_KEY / OPENAI_API_KEY / PERPLEXITY_API_KEY are also
--    honored as a fallback, but WezTerm's Lua does NOT inherit shell rc exports,
--    so settings.lua is preferred.)
--
--  Usage: require("ai").apply_to_config(config)
-- ==========================================================================

local wezterm = require("wezterm")
local M = {}

-- ── Configuration ────────────────────────────────────────────────────────

M.default_provider = "claude"

-- Provider order — drives pick_provider() fallback and the /model picker layout.
M.providers = { "claude", "gpt", "perplexity" }

-- Supported models per provider. First entry is the default when no explicit
-- selection has been made. Edit freely — these are just labels sent in the
-- API `model` field. Use `/model` inside AI Chat (CMD+SHIFT+N) to switch.
M.models = {
  claude = {
    "claude-sonnet-4-5",
    "claude-opus-4-5",
    "claude-haiku-4-5",
    "claude-sonnet-4-20250514",
    "claude-3-5-sonnet-20241022",
  },
  gpt = {
    "gpt-5.3",
    "gpt-5.4",
  },
  perplexity = {
    "sonar",
    "sonar-pro",
    "sonar-reasoning",
    "sonar-reasoning-pro",
    "sonar-deep-research",
  },
}

-- Runtime selection (nil = fall back to the first model of the first provider
-- with a valid API key). Updated by `pick_model()`.
local active_provider = nil
local active_model = nil

-- Lazy-fetched live model list per provider. Populated on first `\model`
-- invocation, reused for the session. `\model` picker offers a refresh option.
-- Empty/missing entries fall back to the hardcoded `M.models[provider]`.
local fetched_models = {}

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
    _settings.perplexity = file_settings.perplexity
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
  if not _settings.perplexity then
    local v = os.getenv("PERPLEXITY_API_KEY")
    if v and #v > 0 then _settings.perplexity = v end
  end
end

local function get_api_key(provider)
  load_settings()
  if provider == "claude" then
    return _settings.anthropic
  elseif provider == "gpt" then
    return _settings.openai
  elseif provider == "perplexity" then
    return _settings.perplexity
  end
  return nil
end

local function pick_provider()
  if get_api_key(M.default_provider) then return M.default_provider end
  for _, p in ipairs(M.providers) do
    if p ~= M.default_provider and get_api_key(p) then return p end
  end
  return nil
end

-- Fetch the live model list from the provider's /v1/models endpoint.
-- Returns a list of model id strings on success, or nil on any failure.
-- Perplexity has no public /models endpoint — always use the hardcoded list.
local function fetch_models(provider)
  local key = get_api_key(provider)
  if not key then return nil end
  if provider == "perplexity" then return nil end

  local url, headers
  if provider == "claude" then
    url = "https://api.anthropic.com/v1/models"
    headers = string.format(
      "-H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01'", key)
  else
    url = "https://api.openai.com/v1/models"
    headers = string.format("-H 'Authorization: Bearer %s'", key)
  end

  local cmd = string.format("curl -s -m 10 '%s' %s 2>/dev/null", url, headers)
  local h = io.popen(cmd)
  if not h then return nil end
  local body = h:read("*a")
  h:close()
  if not body or #body == 0 then return nil end

  local ids = {}
  for id in body:gmatch('"id"%s*:%s*"([^"]+)"') do
    table.insert(ids, id)
  end
  if #ids == 0 then return nil end

  -- OpenAI's list contains embeddings, whisper, dall-e, fine-tunes, etc.
  -- Keep only GPT-5.3 and GPT-5.4 variants.
  if provider == "gpt" then
    local filtered = {}
    for _, id in ipairs(ids) do
      if id:match("^gpt%-5%.3") or id:match("^gpt%-5%.4") then
        table.insert(filtered, id)
      end
    end
    ids = filtered
  end
  if #ids == 0 then return nil end

  -- Sort descending so newer-looking ids surface first.
  table.sort(ids, function(a, b) return a > b end)
  return ids
end

-- Return the list of model ids to offer for a provider. Prefers the live
-- fetched cache; otherwise tries to fetch (and caches on success); otherwise
-- falls back to the hardcoded list in `M.models`.
local function get_models(provider)
  if fetched_models[provider] then return fetched_models[provider] end
  local ids = fetch_models(provider)
  if ids and #ids > 0 then
    fetched_models[provider] = ids
    return ids
  end
  return M.models[provider] or {}
end

-- Returns (provider, model). Uses the runtime selection if set, otherwise
-- the first model of the first provider with a valid key.
local function get_active()
  if active_provider and active_model then
    return active_provider, active_model
  end
  local p = pick_provider()
  if not p then return nil, nil end
  local list = M.models[p]
  return p, (list and list[1]) or p
end

local function current_model_label()
  local _, m = get_active()
  return m or "no api key"
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
  local provider, model = get_active()
  if not provider then
    return nil, NO_KEY_MSG
  end

  local api_key = get_api_key(provider)

  -- Build JSON payload and write to temp file to avoid all shell escaping pain
  local payload, url, headers
  local sys = system_prompt:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
  local usr = user_message:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t')
  if provider == "claude" then
    url = "https://api.anthropic.com/v1/messages"
    payload = '{"model":"' .. model .. '","max_tokens":1024,'
      .. '"system":"' .. sys .. '",'
      .. '"messages":[{"role":"user","content":"' .. usr .. '"}]}'
    headers = string.format(
      "-H 'Content-Type: application/json' -H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01'",
      api_key
    )
  elseif provider == "perplexity" then
    -- Perplexity exposes an OpenAI-compatible /chat/completions endpoint.
    url = "https://api.perplexity.ai/chat/completions"
    payload = '{"model":"' .. model .. '","max_tokens":1024,'
      .. '"messages":[{"role":"system","content":"' .. sys .. '"},'
      .. '{"role":"user","content":"' .. usr .. '"}]}'
    headers = string.format(
      "-H 'Content-Type: application/json' -H 'Authorization: Bearer %s'",
      api_key
    )
  else
    url = "https://api.openai.com/v1/chat/completions"
    payload = '{"model":"' .. model .. '","max_tokens":1024,'
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

  -- Parse response. Perplexity uses the same OpenAI-compatible shape,
  -- so anything non-Claude reads from the `content` field.
  local text
  if provider == "claude" then
    text = body:match('"text"%s*:%s*"(.-)"')
  else
    text = body:match('"content"%s*:%s*"(.-)"')
  end

  if text then
    -- JSON string unescape. Hide escaped backslashes first so later passes
    -- don't misinterpret the trailing char (e.g. `\\n` = literal backslash-n,
    -- not a newline). NUL byte is a safe placeholder — never appears in API text.
    text = text
      :gsub("\\\\", "\0")
      :gsub('\\"', '"')
      :gsub("\\n", "\n")
      :gsub("\\r", "\r")
      :gsub("\\t", "\t")
      :gsub("\0", "\\")
    return text, nil
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
  local model_label = current_model_label()
  local context = get_selection(window, pane)
  if not context then
    show_result(window, "AI Command Suggest [" .. model_label .. "]",
      "No text selected.\n\nHow to use:\n  1. Select some terminal output (click+drag or enter Copy Mode)\n  2. Press CMD+SHIFT+I")
    return
  end

  show_result(window, "AI Command Suggest [" .. model_label .. "]", "Thinking... (this tab will update)")

  local response, err = call_ai(
    "You are a terminal command expert. The user shows terminal output (possibly errors). "
    .. "Suggest the best command(s) to fix it. Reply ONLY with commands, one per line. "
    .. "If multiple steps, number them. No markdown fences.",
    context
  )

  if err then
    show_result(window, "AI Error [" .. model_label .. "]", err)
  else
    show_result(window, "AI Suggested Commands [" .. model_label .. "]", response)
  end
end

-- ── Feature 2: AI Explain Output ─────────────────────────────────────────

local function ai_explain_output(window, pane)
  local model_label = current_model_label()
  local context = get_selection(window, pane)
  if not context then
    show_result(window, "AI Explain [" .. model_label .. "]",
      "No text selected.\n\nHow to use:\n  1. Select some terminal output (click+drag or enter Copy Mode)\n  2. Press CMD+SHIFT+X")
    return
  end

  show_result(window, "AI Explain [" .. model_label .. "]", "Thinking... (this tab will update)")

  local response, err = call_ai(
    "You are a helpful terminal assistant. Explain the following terminal output in plain English. "
    .. "Be concise but thorough. If there are errors, explain the cause and how to fix them. "
    .. "Format for easy terminal reading, no markdown.",
    context
  )

  if err then
    show_result(window, "AI Error [" .. model_label .. "]", err)
  else
    show_result(window, "AI Explanation [" .. model_label .. "]", response)
  end
end

-- ── Feature 3: AI Git Commit Message ─────────────────────────────────────

local function ai_git_commit(window, pane)
  local model_label = current_model_label()
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
    show_result(window, "AI Git Commit [" .. model_label .. "]", "No git changes found (staged or unstaged).")
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
    show_result(window, "AI Error [" .. model_label .. "]", err)
    return
  end

  -- Type the commit command into the original pane
  local first_line = response:match("^([^\n]+)")
  if first_line then
    pane:send_text('git commit -m "' .. first_line:gsub('"', '\\"') .. '"')
  end
end

-- ── Model picker (shared) ─────────────────────────────────────────────────

-- Open an InputSelector listing every supported model across providers.
-- Model lists are fetched live from each provider's /v1/models endpoint on
-- first use and cached for the session; providers without a key fall back
-- to the hardcoded list. Selecting "Refresh" clears the cache and re-fetches.
local pick_model
pick_model = function(window, pane, on_done)
  local choices = {
    { id = "__refresh__", label = "↻  Refresh model list from API" },
  }
  for _, provider in ipairs(M.providers) do
    local has_key = get_api_key(provider) ~= nil
    local list = get_models(provider)
    local source = fetched_models[provider] and "live" or "fallback"
    for _, model in ipairs(list) do
      local marker = (provider == active_provider and model == active_model) and "● " or "  "
      local suffix = has_key and ("   (" .. source .. ")") or "   (no api key)"
      table.insert(choices, {
        id = provider .. "|" .. model,
        label = marker .. string.format("%-12s  %s%s", "[" .. provider .. "]", model, suffix),
      })
    end
  end

  window:perform_action(
    wezterm.action.InputSelector({
      title = "  Select AI model  (Enter: use  ·  Esc: cancel)",
      choices = choices,
      fuzzy = true,
      fuzzy_description = "Type to filter models:",
      action = wezterm.action_callback(function(w, p, id, _)
        if id == "__refresh__" then
          fetched_models = {}
          pick_model(w, p, on_done)
          return
        end
        if id then
          local provider, model = id:match("^([^|]+)|(.+)$")
          if provider and model then
            active_provider = provider
            active_model = model
          end
        end
        if on_done then on_done(w, p) end
      end),
    }),
    pane
  )
end

-- ── Feature 4: AI Chat (multi-turn conversation) ─────────────────────────

-- Persistent chat history. Module-level so the session survives closing and
-- re-opening the prompt — user can pause, read the response, then reinvoke
-- CMD+SHIFT+N and keep going with full context.
local chat_history = {}

-- Inline commands recognised instead of being sent as user messages
local CHAT_HELP = [[Inline commands:
  /new     Start a fresh chat (clears history)
  /show    Open the full transcript in a new tab
  /model   Switch AI model
  /end     End and clear the session
  /help    Show this help
(Empty input or Esc pauses the session — reinvoke CMD+SHIFT+N to resume.)]]

local function build_transcript(history)
  if #history == 0 then return "(empty chat — type something to begin)" end
  local parts = {}
  for _, t in ipairs(history) do
    table.insert(parts, (t.role == "user" and "── You ──" or "── AI ──"))
    table.insert(parts, t.text)
    table.insert(parts, "")
  end
  return table.concat(parts, "\n")
end

local function last_assistant(history)
  for i = #history, 1, -1 do
    if history[i].role == "assistant" then return history[i].text end
  end
  return nil
end

local function chat_description(history, model_label)
  local parts = {
    { Attribute = { Intensity = "Bold" } },
    { Foreground = { Color = "#89b4fa" } },
    { Text = "  AI Chat [" .. model_label .. "]" },
  }
  if #history > 0 then
    local turns = 0
    for _, t in ipairs(history) do if t.role == "user" then turns = turns + 1 end end
    table.insert(parts, {
      Text = string.format("  (%d turn%s)", turns, turns == 1 and "" or "s"),
    })
  end

  local resp = last_assistant(history)
  if resp then
    table.insert(parts, { Attribute = { Intensity = "Normal" } })
    table.insert(parts, { Foreground = { Color = "#cdd6f4" } })
    -- Cap preview so description stays readable; \show has the full thing.
    local preview = resp
    if #preview > 1200 then preview = preview:sub(1, 1200) .. "\n… (truncated — use /show for full)" end
    table.insert(parts, { Text = "\n\n" .. preview .. "\n" })
  end

  table.insert(parts, { Attribute = { Intensity = "Bold" } })
  table.insert(parts, { Foreground = { Color = "#f9e2af" } })
  table.insert(parts, { Text = "\n  You (/new /show /model /end /help  ·  Esc=pause):" })
  return wezterm.format(parts)
end

local run_chat
run_chat = function(window, pane)
  local model_label = current_model_label()
  window:perform_action(
    wezterm.action.PromptInputLine({
      description = chat_description(chat_history, model_label),
      action = wezterm.action_callback(function(w, p, line)
        if not line or #line == 0 then return end  -- pause (keep history)

        -- Inline commands
        if line == "/new" then
          chat_history = {}
          run_chat(w, p)
          return
        elseif line == "/end" then
          chat_history = {}
          return
        elseif line == "/show" then
          show_result(w, "AI Chat Transcript [" .. model_label .. "]",
            build_transcript(chat_history))
          return
        elseif line == "/model" then
          pick_model(w, p, function(w2, p2) run_chat(w2, p2) end)
          return
        elseif line == "/help" then
          show_result(w, "AI Chat Help [" .. model_label .. "]", CHAT_HELP)
          return
        end

        table.insert(chat_history, { role = "user", text = line })

        local convo = ""
        for _, turn in ipairs(chat_history) do
          convo = convo .. (turn.role == "user" and "User: " or "Assistant: ")
            .. turn.text .. "\n\n"
        end

        local response, err = call_ai(
          "You are a helpful AI assistant conversing with the user in a terminal window. "
          .. "Reply in plain text suitable for terminal display — no markdown fences, no HTML. "
          .. "Use clear line breaks and keep responses focused. The conversation below is "
          .. "the full history so far; respond to the latest user turn.",
          convo
        )

        if err then
          show_result(w, "AI Chat Error [" .. model_label .. "]", err)
          return
        end

        local clean = (response or ""):gsub("\r", "")
        clean = clean:gsub("^%s+", ""):gsub("%s+$", "")
        table.insert(chat_history, { role = "assistant", text = clean })
        run_chat(w, p)
      end),
    }),
    pane
  )
end

local function ai_chat(window, pane)
  run_chat(window, pane)
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
      local ok, err = pcall(ai_chat, window, pane)
      if not ok then
        wezterm.log_error("AI chat error: " .. tostring(err))
      end
    end),
  })
end

return M
