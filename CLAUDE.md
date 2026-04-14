# WezTerm Config — Agent Guide

Modular WezTerm (Lua) configuration for macOS. All files live here and are symlinked into `~/.config/wezterm/` via `install.sh`.

## Architecture

```
wezterm.lua       Main config — appearance, keybindings, SSH tab title resolution
├── state.lua     Shared state (pane_id → connection tracking for tab titles)
├── ai.lua        AI features (Claude/OpenAI) — command suggest, explain, commit msg, chat
├── snippets.lua  Snippet picker + add/delete manager
│   ├── settings.snippets    Curated snippets (field in settings.lua, seeded from settings.lua.example)
│   └── user_snippets.lua    Dynamic snippets (NOT in repo, written by CMD+SHIFT+Z)
├── hosts.lua     SSH/SFTP host launcher — parses ~/.ssh/config
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
- **`settings.lua` is the single user-local config file.** It holds API keys, `otp_command`, and the curated `snippets` table — WezTerm's Lua does NOT inherit shell env vars (`os.getenv` fails for vars in `.zshrc`), so everything user-specific lives in `~/.config/wezterm/settings.lua`. Shape: `{ openai = "sk-...", anthropic = "sk-ant-...", otp_command = "/abs/path/to/cmd", snippets = { { label, command, desc }, ... } }`. `wezterm.lua` / `ai.lua` / `snippets.lua` all load it via `pcall(require, "settings")`. The CMD+SHIFT+J handler opens an instruction tab when `otp_command` is missing; the snippet launcher falls back to an empty list + hint when `settings.snippets` is unset.
- **Shell commands use `io.popen`.** `wezterm.run_child_process` had issues finding binaries outside WezTerm's PATH. All shell calls (OTP, AI curl, git diff) use `io.popen` with absolute paths where needed.
- **AI calls via curl temp file.** JSON payloads are written to a temp file and sent with `curl -d @file` to avoid shell escaping issues.
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
| `CMD+SHIFT+H` | Host launcher (SSH/SFTP → tab or split) | hosts.lua |
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
