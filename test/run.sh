#!/usr/bin/env bash
# Tests for rex-reopen-tab. Starts an isolated Rex server in a temporary
# folder, so your own sessions are not touched.
#
# Usage: test/run.sh
# shellcheck disable=SC1010  # "do" is a rex subcommand here, not the shell keyword.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/rex-reopen-tab-test.XXXXXX)"
sock="unix://$tmp/rex.sock"
unset REX_SESSION REX_BLOCK REX_SERVER
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

rx() { rex -S "$sock" --autostart=false "$@"; }
failures=0
step() { printf '\n== %s\n' "$1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
pass() { echo "ok   $1"; }

printf 'dofile("%s/src/actions.lua"){ state = "%s/closed-tabs.json" }\n' "$root" "$tmp" > "$tmp/init.lua"
rex server run --listen "$sock" --state-dir "$tmp/state" --config "$tmp/init.lua" > "$tmp/server.log" 2>&1 &
pids+=($!)
for _ in $(seq 50); do rx server status >/dev/null 2>&1 && break; sleep 0.2; done

step "close cases (stubbed)"
rx do --all --for 30s "$root/test/close_cases.lua" tracker="$root/src/tracker.lua" out="$tmp/close.json" \
  > "$tmp/close.out" 2>&1 || fail "close cases"
grep -E '^(ok|FAIL)' "$tmp/close.out" || true

step "agent commands (stubbed)"
mkdir -p "$tmp/claude/sessions" "$tmp/pi"
CLAUDE_CONFIG_DIR="$tmp/claude" rx do --all --for 30s "$root/test/agent_commands.lua" \
  tracker="$root/src/tracker.lua" out="$tmp/agents.json" pi_sessions="$tmp/pi" > "$tmp/agents.out" 2>&1 \
  || fail "agent commands"
grep -E '^(ok|FAIL)' "$tmp/agents.out" || true

step "shell tab on a live server"
rx do --all "$root/src/tracker.lua" state="$tmp/closed-tabs.json" pi_sessions="$tmp/pi" > "$tmp/tracker.log" 2>&1 &
pids+=($!)
sleep 2
mkdir -p "$tmp/a" "$tmp/b"
json_field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
session="$(rx session new test --json | json_field 'd["session_id"]')"
created="$(rx window new -s "$session" -c "$tmp/a" --json)"
window="$(echo "$created" | json_field 'd["window_id"]')"
block="$(echo "$created" | json_field 'd["block_ids"][0]')"
sleep 2
rx block send -s "$session" -b "$block" "cd $tmp/b" >/dev/null
rx block send-key -s "$session" -b "$block" enter >/dev/null
sleep 3
rx window close -s "$session" "$window"
sleep 2
if grep -q "recorded $window" "$tmp/tracker.log"; then pass "closed tab recorded"; else fail "closed tab recorded"; fi

reopened="$(rx do -s "$session" reopen_closed_tab 2>&1 || true)"
new_window="$(echo "$reopened" | json_field 'd.get("window_id", "")' 2>/dev/null || true)"
if [ -n "$new_window" ]; then pass "reopen_closed_tab"; else fail "reopen_closed_tab: $reopened"; fi
sleep 3
new_block="$(rx window inspect -s "$session" "$new_window" --json | json_field 'd["layers"][0]["blocks"][0]["block_id"]')"
cwd="$(rx block call -s "$session" -b "$new_block" process | json_field 'd["foreground"]["cwd"]')"
if [ "$cwd" = "$(cd "$tmp/b" && pwd -P)" ]; then pass "reopened in the folder after cd"; else fail "folder: got $cwd"; fi

empty="$(rx do -s "$session" reopen_closed_tab 2>&1 || true)"
if echo "$empty" | grep -q "No closed tab to reopen"; then pass "empty list gives an error"; else fail "empty list: $empty"; fi

rx window new -s "$session" -c "$tmp/a" --shell none --json -- /bin/sleep 1 > /dev/null
sleep 3
if grep -q ": program exited" "$tmp/tracker.log" && [ "$(grep -c ' recorded ' "$tmp/tracker.log")" = 1 ]; then
  pass "program exit not recorded"
else
  fail "program exit not recorded"
fi

if grep -q "slow" "$tmp/tracker.log"; then fail "slow handler or command logged"; else pass "no slow handler or command"; fi

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures failed"; exit 1; fi
