-- ==========================================================================
--  state.lua — Shared state between wezterm.lua and ai.lua
--  Stores pane_id → connection info for tab title resolution
-- ==========================================================================

local M = {}

-- pane_id → { proto = "ssh"|"sftp", host = "alias-name" }
M.pane_connections = {}

return M
