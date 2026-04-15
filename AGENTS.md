# WezTerm Config — Agent Guide

Modular WezTerm (Lua) configuration for macOS. All files live here and are symlinked into `~/.config/wezterm/` via `install.sh`.

## Architecture

```
wezterm.lua       Main config — appearance, keybindings, SSH tab title resolution
├── state.lua     Shared state (pane_id → connection tracking for tab titles)
├── ai.lua        AI features (Claude/OpenAI/Perplexity) — suggest, explain, commit msg, chat
├── snippets.lua  Snippet picker + add/delete manager
│   ├── settings.snippets    Curated snippets (field in settings.lua, seeded from settings.lua.example)
│   └── user_snippets.lua    Dynamic snippets (NOT in repo, written by CMD+SHIFT+Z)
├── hosts.lua     SSH/SFTP host launcher — parses ~/.ssh/config
│   └── remote_dirs.lua     Per-host remote dir history (NOT in repo, written by hosts.lua)
├── resurrect.lua Session / pane layout persistence (wraps resurrect.wezterm plugin)
└── help.lua      Searchable shortcut cheat sheet (hardcoded list — keep in sync!)

settings.lua      API keys, otp_command, curated snippets (NOT in repo, stays in ~/.config/wezterm/)
```

## Key Design Decisions

- **No tmux.** All multiplexing is native WezTerm — panes, tabs, workspaces.
- **Single-chord keybindings.** Every shortcut is one `CMD+SHIFT+key` combo, no leader key.
- **Modules loaded via pcall.** If any module fails, the rest of the config still works. Pattern:
  ```lua
  local ok, mod = pcall(require, "module")
  if not ok then mod = nil end
  -- ... later:
  if mod then mod.apply_to_config(config) end
  ```
- **SSH hostname resolution.** `wezterm.lua` parses `~/.ssh/config` at load time into `ssh_lookup` table. Maps IPs, hostnames, User-field-embedded-IPs, and suffixes all back to Host aliases. Tab titles show the alias (e.g., `region-app-env-role-NN`) instead of raw IPs. The parser must exclude `HostName`/`HostKeyAlgorithms` lines — uses `not trimmed:match("^%s*[Hh]ost[A-Za-z]")`.
- **Complex SSH User fields.** Some entries have `User user@jumphost@10.0.0.1` (jump host embedded in User). The parser extracts every IP and every `@suffix` from the User field and maps each to the Host alias.
- **Tab title tracking.** `state.pane_connections` maps `pane_id → {proto, host}`. Set by `hosts.lua` when launching, also set by `wezterm.lua`'s `format-tab-title` event when it detects SSH/SFTP by process name or pane title. Once resolved, the mapping is cached.
- **`settings.lua` is the single user-local config file.** It holds API keys, `otp_command`, and the curated `snippets` table — WezTerm's Lua does NOT inherit shell env vars (`os.getenv` fails for vars in `.zshrc`), so everything user-specific lives in `~/.config/wezterm/settings.lua`. Shape: `{ openai = "sk-...", anthropic = "sk-ant-...", perplexity = "pplx-...", otp_command = "/abs/path/to/cmd", snippets = { { label, command, desc }, ... } }`. `wezterm.lua` / `ai.lua` / `snippets.lua` all load it via `pcall(require, "settings")`. The CMD+SHIFT+J handler opens an instruction tab when `otp_command` is missing; the snippet launcher falls back to an empty list + hint when `settings.snippets` is unset.
- **Shell commands use `io.popen`.** `wezterm.run_child_process` had issues finding binaries outside WezTerm's PATH. All shell calls (OTP, AI curl, git diff) use `io.popen` with absolute paths where needed.
- **AI calls via curl temp file.** JSON payloads are written to a temp file and sent with `curl -d @file` to avoid shell escaping issues. Responses are parsed by walking the JSON string manually (`extract_json_string` in `ai.lua`) — Lua's lazy `.-` pattern stops at the first `"` even when it's an escaped `\"`, which would silently truncate any reply containing a quote.
- **AI providers + runtime model picker.** `ai.lua` supports Claude, OpenAI (GPT-5.x), and Perplexity. Active `(provider, model)` is runtime-selectable via `/model` inside CMD+SHIFT+N chat (also switches which model the one-shot features use). Model lists are lazy-fetched from each provider's `/v1/models` endpoint on first use and cached for the session; Perplexity has no public `/models` so it falls back to the hardcoded list. Without an explicit pick, `get_active()` returns the first provider in `M.providers` that has a key, and that provider's first model.
- **AI Chat session state is module-level.** `chat_history` in `ai.lua` outlives a single prompt — Esc / empty input pauses the session; reinvoking CMD+SHIFT+N resumes with full context. Inline commands: `/new` clears, `/show` opens transcript, `/model` switches model, `/end` clears + exits, `/help` lists them.
- **Remote dir history (SSH + SFTP).** After picking a host, `hosts.lua` shows a single flat picker listing `(dir × where-to-open)` — each history entry plus Default/Type expands into 3 choices (New Tab / Split Right / Split Down), and each history entry gets a 4th "🗑 Remove from history" variant. The selected dir is recorded MRU-first in `~/.config/wezterm/remote_dirs.lua` (shape `{ [host] = {…} }`, capped at 15 entries per host). SSH and SFTP **share the same per-host list** — connecting via either proto populates and reads the same history. Old per-proto files (`{ ssh = {…}, sftp = {…} }`) are auto-migrated on load by merging both lists per host. Launch commands: SFTP uses `sftp 'host:/remote/dir'` since sftp(1) cds before the prompt when given `host:path`; SSH uses `ssh -t host 'cd /remote/dir 2>/dev/null; exec ${SHELL:-/bin/bash} -l'` — `-t` forces a PTY, single quotes keep it one argv entry, and `exec` replaces the wrapper so the login shell owns the PTY. The file lives outside the repo and uses the same `package.loaded[...] = nil` trick as `user_snippets.lua` so edits land without a reload. **Critical constraint:** chaining 3 `InputSelector`s from callbacks silently drops the deepest callback in wezterm — that's why the dir and where-to-open choices are baked into a single picker instead of two chained ones.
- **Long tab names trimmed from front**, not end: `region-app-env-role-NN` → `...app-env-role-NN`.

## Keybinding Map

| Key | Action | Module |
|-----|--------|--------|
| `CMD+D` | Split pane right | wezterm.lua |
| `CMD+SHIFT+D` | Split pane down | wezterm.lua |
| `CTRL+SHIFT+Arrow` | Navigate panes | wezterm.lua |
| `ALT+SHIFT+Arrow` | Resize panes | wezterm.lua |
| `CMD+SHIFT+Enter` | Zoom/unzoom pane | wezterm.lua |
| `CMD+W` | Close pane | wezterm.lua |
| `CMD+SHIFT+R` | Rotate panes | wezterm.lua |
| `CMD+T` | New tab | wezterm.lua |
| `CMD+1-9` | Jump to tab | wezterm.lua |
| `CMD+SHIFT+] / [` | Next/prev tab | wezterm.lua |
| `CMD+SHIFT+C` | Copy mode | wezterm.lua |
| `CMD+F` | Search scrollback | wezterm.lua |
| `CMD+SHIFT+F` | Quick select | wezterm.lua |
| `CMD+K` | Clear scrollback | wezterm.lua |
| `CMD+SHIFT+P` | Command palette | wezterm.lua |
| `CMD+SHIFT+L` | Reload config | wezterm.lua |
| `CMD+SHIFT+E` | Edit config in $EDITOR | wezterm.lua |
| `CMD+SHIFT+J` | OTP auto-fill (runs `settings.otp_command`) | wezterm.lua |
| `CMD+SHIFT+I` | AI suggest fix | ai.lua |
| `CMD+SHIFT+X` | AI explain output | ai.lua |
| `CMD+SHIFT+G` | AI git commit message | ai.lua |
| `CMD+SHIFT+N` | AI chat (multi-turn conversation) | ai.lua |
| `CMD+SHIFT+S` | Snippet launcher | snippets.lua |
| `CMD+SHIFT+Z` | Manage user snippets — add / delete (writes `user_snippets.lua`) | snippets.lua |
| `CMD+SHIFT+H` | Host launcher (SSH/SFTP → dir + target) | hosts.lua |
| `CMD+SHIFT+B` | Save current session (pane layout) now | resurrect.lua |
| `CMD+SHIFT+Y` | Restore saved session / pane layout | resurrect.lua |
| `CMD+SHIFT+M` | Shortcut help | help.lua |

## Known Gotchas

- **`help.lua` shortcuts list is hardcoded.** When adding/changing keybindings, update the `shortcuts` table in `help.lua` manually.
- **SSH config parser regex.** `^[Hh]ost%s+(.+)$` matches both `Host` and `HostName`. The extra check `not trimmed:match("^%s*[Hh]ost[A-Za-z]")` is critical — removing it silently breaks the entire config including OTP.
- **`settings.lua` is gitignored.** It lives only at `~/.config/wezterm/settings.lua`. The repo has `settings.lua.example` as a template.
- **`install.sh` must be run from the repo directory** so symlink targets resolve to absolute paths.
- **macOS lazygit config** is at `~/Library/Application Support/lazygit/config.yml`, NOT `~/.config/lazygit/`.
- **WezTerm Lua `pane:split()`** is the correct API for splitting panes programmatically. `wezterm.action.SplitPane` with `command = SpawnCommand(...)` does NOT work from inside `action_callback`.
- **`window:get_selection_text_for_pane(pane)`** — NOT `pane:get_selection_text_for_pane()`. The window object owns the selection API.
- **OTP command lives in `settings.lua`** as `otp_command` (absolute path required — WezTerm Lua has no shell PATH). If unset, CMD+SHIFT+J shows a toast rather than running anything.
- **Snippets live in their own module.** `snippets.lua` owns both the picker (CMD+SHIFT+S) and the add/delete manager (CMD+SHIFT+Z) — not `ai.lua`. Curated defaults come from `settings.snippets` (inside `~/.config/wezterm/settings.lua`, seeded from `settings.lua.example`). Dynamic adds go to a separate `~/.config/wezterm/user_snippets.lua` so we never rewrite the user's secrets file. `load_all_snippets()` merges both sources, clearing `package.loaded["settings"]` and `package.loaded["user_snippets"]` before each require so edits appear without a config reload. The "Delete existing" option is hidden from the menu when `user_snippets.lua` is empty.
- **GPT-5.x rejects `max_tokens`.** The OpenAI branch of `call_ai` must send `max_completion_tokens` instead. Claude and Perplexity still use `max_tokens` — don't collapse the three branches.
- **`show_result` spawns a fresh tab every call.** It's synchronous `less` on a temp file, so you can't pre-spawn a "Thinking…" placeholder and then update it — the second call creates a sibling tab, leaving a stale one behind. Call `show_result` exactly once, after the API response is in hand.
- **Three chained `InputSelector`s drop the deepest callback.** Dispatching a third `InputSelector` via `window:perform_action` from inside a level-2 callback fires the action but silently never runs its `action_callback`. `wezterm.time.call_after`, custom `EmitEvent`, and a level-3 `PromptInputLine` were also unreliable for this launcher on the current runtime. Flatten by baking choices into a single picker (see `hosts.lua`'s `remote_dir_picker` which combines dir × where-to-open).
- **`resurrect.wezterm` plugin API is unstable.** `resurrect.lua` wraps every plugin entrypoint in a `safe()` helper (pcall + log) because the plugin's module layout has drifted across releases (`state_manager` vs `save_state`, `workspace_state` vs `tab_state`, etc.). The plugin fetches from GitHub on first `wezterm.plugin.require` — first launch after a fresh install has a brief network stall. Restored panes re-spawn the original command; running processes and live shell state do NOT survive a restart, only cwd + launch command + optional scrollback-as-text.

## Adding a New Keybinding

1. Pick an unused `CMD+SHIFT+key` combo (check the table above).
2. Add the binding to the appropriate module's `apply_to_config()`, or to `config.keys` in `wezterm.lua`.
3. Wrap the callback in `pcall` so errors don't break the config.
4. Update `help.lua`'s `shortcuts` table.

## Adding a New Module

1. Create `mymodule.lua` with `local M = {}` / `function M.apply_to_config(config)` / `return M`.
2. In `wezterm.lua`, add: `local mod_ok, mod = pcall(require, "mymodule")` and `if mod then mod.apply_to_config(config) end`.
3. If it needs pane tracking, `require("state")` and write to `state.pane_connections`.
4. Run `install.sh` to symlink the new file.

## Related Config (outside this repo)

- **lazygit:** `~/Library/Application Support/lazygit/config.yml` — delta side-by-side diffs
- **git:** `~/.gitconfig` — `core.editor = hx` (helix), `core.pager = delta`, `delta.side-by-side = true`
- **settings:** `~/.config/wezterm/settings.lua` — API keys + otp_command (not in repo)
