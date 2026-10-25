#!/usr/bin/env bash
# Install rex-reopen-tab: Reopen Closed Tab for the Rex terminal (macOS).
# Run it again after `git pull` to update. Remove it with ./uninstall.sh.
#
# Usage: ./install.sh [--key KEY] [--no-pi]
#   --key KEY  key for Reopen Closed Tab (default cmd+shift+t; "" for none)
#   --no-pi    do not install the pi extension
set -euo pipefail

LABEL="io.github.yogevkr.rex-reopen-tab"
MARK_BEGIN="-- >>> rex-reopen-tab >>> (managed by install.sh; uninstall.sh removes it)"
MARK_END="-- <<< rex-reopen-tab <<<"

key=""
key_set=0
install_pi=1
while [ $# -gt 0 ]; do
  case "$1" in
    --key) key="${2-}"; key_set=1; shift 2 ;;
    --no-pi) install_pi=0; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "rex-reopen-tab needs macOS (it uses launchd, lsof, and BSD pgrep)." >&2
  exit 1
fi

src="$(cd "$(dirname "$0")" && pwd)/src"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
dest="$config_home/rex/reopen-tab"
config_file="${REX_CONFIG:-$config_home/rex/init.lua}"
state_dir="$HOME/.local/state/rex-reopen-tab"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
pi_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"

# The LaunchAgent needs a stable path to the rex CLI.
rex_bin="${REX_BIN:-$(command -v rex || true)}"
if [ -z "$rex_bin" ]; then
  rex_bin="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
fi
if [ ! -x "$rex_bin" ]; then
  echo "cannot find the rex CLI. Install Rex, or set REX_BIN=/path/to/rex." >&2
  exit 1
fi

echo "rex:     $rex_bin"
echo "files:   $dest"
echo "config:  $config_file"
echo "state:   $state_dir"

mkdir -p "$dest" "$state_dir" "$(dirname "$config_file")" "$(dirname "$plist")"
cp "$src/tracker.lua" "$src/actions.lua" "$dest/"

# init.lua: replace our block, keep everything else.
lua_string() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
opts="{}"
if [ "$key_set" = 1 ]; then opts="{ key = $(lua_string "$key") }"; fi
tmp="$(mktemp)"
if [ -f "$config_file" ]; then
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$config_file" > "$tmp"
fi
{
  printf '%s\n' "$MARK_BEGIN"
  printf 'dofile(%s)%s\n' "$(lua_string "$dest/actions.lua")" "$opts"
  printf '%s\n' "$MARK_END"
} >> "$tmp"
cat "$tmp" > "$config_file"
rm -f "$tmp"

# LaunchAgent that keeps the tracker running.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$rex_bin")</string>
		<string>--autostart=false</string>
		<string>do</string>
		<string>--all</string>
		<string>$(xml "$dest/tracker.lua")</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>15</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$(xml "$state_dir/tracker.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$state_dir/tracker.log")</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"

if [ "$install_pi" = 1 ] && { [ -d "$pi_dir" ] || command -v pi >/dev/null 2>&1; }; then
  mkdir -p "$pi_dir/extensions"
  cp "$src/pi-extension.ts" "$pi_dir/extensions/rex-reopen-tab.ts"
  echo "pi:      $pi_dir/extensions/rex-reopen-tab.ts (run /reload in open pi sessions)"
fi

if "$rex_bin" --autostart=false config reload >/dev/null 2>&1; then
  if "$rex_bin" --autostart=false keymap 2>/dev/null | grep -q reopen_closed_tab; then
    echo "done:    $("$rex_bin" --autostart=false keymap | grep reopen_closed_tab)"
  else
    echo "done:    the action is loaded (no key bound)"
  fi
else
  echo "done:    the Rex server is not running; it loads the config when it starts"
fi
