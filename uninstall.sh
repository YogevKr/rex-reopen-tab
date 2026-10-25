#!/usr/bin/env bash
# Remove rex-reopen-tab. Keeps the closed-tab list and logs unless --purge.
#
# Usage: ./uninstall.sh [--purge]
set -euo pipefail

LABEL="io.github.yogevkr.rex-reopen-tab"
MARK_BEGIN="-- >>> rex-reopen-tab >>> (managed by install.sh; uninstall.sh removes it)"
MARK_END="-- <<< rex-reopen-tab <<<"

purge=0
case "${1-}" in
  --purge) purge=1 ;;
  "") ;;
  *) echo "usage: $0 [--purge]" >&2; exit 2 ;;
esac

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
dest="$config_home/rex/reopen-tab"
config_file="${REX_CONFIG:-$config_home/rex/init.lua}"
state_dir="$HOME/.local/state/rex-reopen-tab"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
pi_ext="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/rex-reopen-tab.ts"
rex_bin="${REX_BIN:-$(command -v rex || true)}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$plist" "$pi_ext"
rm -rf "$dest"

if [ -f "$config_file" ]; then
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config_file" > "$tmp"
  cat "$tmp" > "$config_file"
  rm -f "$tmp"
fi

if [ "$purge" = 1 ]; then
  rm -rf "$state_dir"
fi

if [ -n "$rex_bin" ]; then
  "$rex_bin" --autostart=false config reload >/dev/null 2>&1 || true
fi
echo "removed rex-reopen-tab$([ "$purge" = 1 ] && echo " and its state" || echo "; state kept in $state_dir")"
