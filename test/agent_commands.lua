-- Reopen commands for Claude, Codex, and pi panes. rex.call and rex.exec are
-- stubbed with fake processes, so no agent runs. Run by test/run.sh with:
-- tracker=PATH out=PATH pi_sessions=DIR, and CLAUDE_CONFIG_DIR set.
local handlers = {}
rex.on = function(name, fn) handlers[name] = fn end
rex.every = function() end
rex.after = function() end
rex.args.state = rex.args.out

local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR")
local PI_DIR = rex.args.pi_sessions

local CLAUDE_SID = "11111111-2222-4333-8444-555555555555"
local CLAUDE_NEW_SID = "66666666-7777-4888-9999-aaaaaaaaaaaa"
local CODEX_SID = "0199aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee"
local PI_SID = "0199ffff-1111-7222-8333-444444444444"
local PI_FILE = PI_DIR .. "/2026-01-02T03-04-05-678Z_" .. PI_SID .. ".jsonl"

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
write(CLAUDE_DIR .. "/sessions/101.json", rex.json.encode({ sessionId = CLAUDE_SID }))
write(CLAUDE_DIR .. "/sessions/500.json", rex.json.encode({ sessionId = CLAUDE_NEW_SID }))
write(PI_FILE, "{}\n")
write(PI_DIR .. "/400.json", rex.json.encode({
  pid = 400, sessionId = PI_SID, sessionFile = PI_FILE, cwd = "/work",
  args = { "--model", "kimi", "--session", "old" },
}))

-- Fake processes: args (ps), children (pgrep), rollout (lsof).
local procs = {
  [100] = { args = "tcr run -- --dangerously-skip-permissions --resume 00000000-0000-4000-8000-000000000000",
            children = { claude = 101 } },
  [101] = { args = "claude --dangerously-skip-permissions" },
  [200] = { args = 'codex -c model_provider="teamcodex" -c model_providers.teamcodex.base_url="http://127.0.0.1:1/v1" '
              .. "--yolo resume 00000000-0000-4000-8000-000000000000",
            rollout = "/home/u/.codex/sessions/2026/01/02/rollout-2026-01-02T03-04-05-" .. CODEX_SID .. ".jsonl" },
  [300] = { args = "codex --yolo" },
  [400] = { args = "node /opt/homebrew/bin/pi" },
  [500] = { args = "/opt/claude/versions/2.1.302/claude --model opus" },
  [600] = { args = "claude" },
}
local conversations = { [CLAUDE_SID] = true }

rex.exec = function(argv)
  local cmd = argv[1]
  if cmd == "/bin/ps" then
    local p = procs[tonumber(argv[#argv])]
    return p and { code = 0, stdout = p.args .. "\n" } or { code = 1, stdout = "" }
  elseif cmd == "/usr/bin/pgrep" then
    local p = procs[tonumber(argv[4])]
    local child = p and p.children and p.children[argv[6]]
    return child and { code = 0, stdout = child .. "\n" } or { code = 1, stdout = "" }
  elseif cmd == "/usr/sbin/lsof" then
    local pid
    for i, w in ipairs(argv) do if w == "-p" then pid = tonumber(argv[i + 1]) end end
    local p = procs[pid]
    local out = "p" .. pid .. "\nfcwd\nn/work\n"
    if p and p.rollout then out = out .. "f20\nn" .. p.rollout .. "\n" end
    return { code = 0, stdout = out }
  elseif cmd == "/bin/sh" then
    return { code = conversations[argv[#argv]] and 0 or 1, stdout = "" }
  end
  return { code = 0, stdout = "" }
end

local S = "session:test"
local panes = {
  { n = "tcr", fg = { pid = 100, name = "tcr", argv0 = "tcr" } },
  { n = "tcx", fg = { pid = 200, name = "codex", argv0 = "codex" } },
  { n = "codex_new", fg = { pid = 300, name = "codex", argv0 = "codex" } },
  { n = "pi", fg = { pid = 400, name = "node", argv0 = "node" } },
  { n = "claude_new", fg = { pid = 500, name = "claude", argv0 = "claude" } },
  { n = "claude_unknown", fg = { pid = 600, name = "claude", argv0 = "claude" } },
}
local windows = {}
for _, p in ipairs(panes) do
  windows[#windows + 1] = {
    window_id = "window:" .. p.n, label = p.n, focused_block_id = "block:" .. p.n,
    layers = { {
      kind = "tiled",
      layout = { block_id = "block:" .. p.n },
      blocks = { { block_id = "block:" .. p.n, label = p.n, flavor = "com.superlogical.terminal.shell" } },
    } },
  }
end
rex.call = function(method)
  if method == "session.view" then return { label = "test", windows = windows } end
  return nil
end

dofile(rex.args.tracker)

handlers.session_view_changed(nil, { session_id = S })
for _, p in ipairs(panes) do
  p.fg.cwd = "/work"
  handlers.block_event(nil, { session_id = S, block_id = "block:" .. p.n, name = "process_changed",
    payload = { foreground = p.fg } })
end
for _, p in ipairs(panes) do
  handlers.window_closed(nil, { session_id = S, window_id = "window:" .. p.n })
end

local f = assert(io.open(rex.args.out, "r"))
local tabs = rex.json.decode(f:read("*a")).tabs
f:close()
local got = {}
for _, t in ipairs(tabs) do got[t.label] = t.panes[1] end

local failures = 0
local function expect(name, mode, input)
  local p = got[name] or {}
  local ok = p.mode == mode and p.input == input and p.cwd == "/work"
  print((ok and "ok   " or "FAIL ") .. name .. ": " .. tostring(p.mode) .. " " .. string.format("%q", tostring(p.input)))
  if not ok then failures = failures + 1 end
end
expect("tcr", "resume", "tcr run -- --dangerously-skip-permissions --resume " .. CLAUDE_SID .. "\n")
expect("tcx", "resume", "tcx run -- --yolo resume " .. CODEX_SID .. "\n")
expect("codex_new", "new", "codex --yolo\n")
expect("pi", "resume", "pi --model kimi --session " .. PI_FILE .. "\n")
expect("claude_new", "new", "claude --model opus\n")
expect("claude_unknown", "picker", "claude --resume\n")
rex.stop(failures == 0 and 0 or 1)
