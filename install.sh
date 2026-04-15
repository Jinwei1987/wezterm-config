#!/bin/bash
# ==========================================================================
#  install.sh — Symlink WezTerm config files to ~/.config/wezterm/
#
#  Usage:    ./install.sh
#  Settings: settings.lua is NOT symlinked (contains secrets + local paths).
#            Copy settings.lua.example to ~/.config/wezterm/settings.lua and fill in.
# ==========================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/.config/wezterm"

FILES=(wezterm.lua ai.lua help.lua hosts.lua resurrect.lua snippets.lua state.lua)

mkdir -p "$TARGET_DIR"

for file in "${FILES[@]}"; do
  src="$SCRIPT_DIR/$file"
  dst="$TARGET_DIR/$file"

  if [ ! -f "$src" ]; then
    echo "⚠ Skipping $file (not found in repo)"
    continue
  fi

  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -f "$dst" ]; then
    echo "⚠ Backing up existing $dst → ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi

  ln -s "$src" "$dst"
  echo "✓ $file → $dst"
done

# Seed settings.lua from example if missing
if [ ! -f "$TARGET_DIR/settings.lua" ]; then
  if [ -f "$SCRIPT_DIR/settings.lua.example" ]; then
    cp "$SCRIPT_DIR/settings.lua.example" "$TARGET_DIR/settings.lua"
    echo ""
    echo "✓ settings.lua created from example at $TARGET_DIR/settings.lua"
    echo "  Edit it to add your API keys and otp_command."
  else
    echo ""
    echo "⚠ settings.lua.example not found in repo; cannot seed $TARGET_DIR/settings.lua"
  fi
fi

echo ""
echo "Done! Reload WezTerm with CMD+SHIFT+L"
