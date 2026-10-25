-- rex-reopen-tab tracker.
--
-- Records each tab that closes while its panes are still running, so the
-- reopen_closed_tab action (actions.lua) can rebuild it. Tabs that close
-- because their program exited are not recorded.
--
-- Run: rex --autostart=false do --all tracker.lua [state=PATH] [pi_sessions=DIR] [max=N]
-- install.sh adds a LaunchAgent that keeps it running.

local HOME = os.getenv("HOME")
local STATE_DIR = HOME .. "/.local/state/rex-reopen-tab"
local STATE = rex.args.state or (STATE_DIR .. "/closed-tabs.json")
-- pi-extension.ts writes <pid>.json files here.
local PI_SESSIONS = (rex.args.pi_sessions or (STATE_DIR .. "/pi")) .. "/"
local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")
local MAX_PER_SESSION = tonumber(rex.args.max) or 20
local REFRESH_SECONDS = 30
local SHELL_FLAVOR = "com.superlogical.terminal.shell"
local SHELLS = { zsh = true, bash = true, fish = true, sh = true, dash = true, nu = true, login = true }
local RUNTIMES = { node = true, bun = true }

-- Wrapper commands that start an agent as `<wrapper> ... -- <agent args>`.
-- Reopen keeps the wrapper and its arguments. Add your own wrappers here.
local WRAPPERS = { tcr = "claude", tcx = "codex" }

-- Wrappers that replace themselves with the agent and add their own flags.
-- When the agent's arguments contain `marker`, reopen runs `command` again
-- and drops each `-c` flag whose value starts with a prefix in `drop`.
local EXEC_WRAPPERS = {
  {
    agent = "codex",
    marker = 'model_provider="teamcodex"',
    command = { "tcx", "run", "--" },
    drop = { "model_provider=", "model_providers.teamcodex." },
  },
}

local sessions = {} -- session_id -> { label, windows = { window_id -> window }, order = { window_id, ... }, gone }
local blocks = {}   -- block_id -> { session_id, label, flavor, cwd, fg, command, app, agent, exited_at, closed_at }

local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local line = os.date("%Y-%m-%d %H:%M:%S ") .. table.concat(parts, " ")
  if io.stderr then
    io.stderr:write(line, "\n")
    io.stderr:flush()
  else
    print(line)
  end
end

-- Runs argv and returns trimmed stdout. Returns nil when the command fails,
-- unless any_code is set.
local function run(argv, any_code)
  local started = os.time()
  local ok, r = pcall(rex.exec, argv)
  -- Handlers run one at a time, so a slow command delays every event.
  if os.time() - started >= 2 then log("slow command:", os.time() - started, "s:", table.concat(argv, " ")) end
  if not ok or type(r) ~= "table" then return nil end
  if r.code ~= 0 and not any_code then return nil end
  return ((r.stdout or ""):gsub("%s+$", ""))
end

local function call(method, params)
  local ok, r = pcall(rex.call, method, params)
  if ok then return r end
  return nil
end

local function exists(path)
  local f = path and io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(rex.json.decode, text)
  if ok then return data end
  return nil
end

local function load_tabs()
  local data = read_json(STATE)
  if type(data) == "table" and type(data.tabs) == "table" then return data.tabs end
  return {}
end

local function save_tabs(tabs)
  local tmp = STATE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    log("cannot write", tmp)
    return
  end
  if #tabs == 0 then
    f:write('{"version":1,"tabs":[]}')
  else
    f:write(rex.json.encode({ version = 1, tabs = tabs }))
  end
  f:close()
  os.rename(tmp, STATE)
end

-- Process helpers ----------------------------------------------------------

local function basename(path)
  return (path or ""):match("[^/]+$") or ""
end

local function is_shell(fg)
  if not fg then return true end
  local name = (fg.name or ""):gsub("^%-", "")
  return SHELLS[name] == true or (fg.argv0 or ""):sub(1, 1) == "-"
end

local function is_id(s)
  return s ~= nil and s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

local function words(s)
  local t = {}
  for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end
  return t
end

local function quote(w)
  if w:match("^[%w%-%._/:=,@%+%%]+$") then return w end
  return "'" .. (w:gsub("'", "'\\''")) .. "'"
end

local function join(t)
  local out = {}
  for i, w in ipairs(t) do out[i] = quote(w) end
  return table.concat(out, " ")
end

local function starts_with_any(s, prefixes)
  for _, p in ipairs(prefixes) do
    if s:sub(1, #p) == p then return true end
  end
  return false
end

-- ps splits on spaces, so an argument that contains a space comes back as
-- two words. Agent flags rarely contain spaces.
local function args_of(pid)
  return run({ "/bin/ps", "-ww", "-o", "args=", "-p", tostring(pid) })
end

local function child_named(pid, name)
  -- -a: by default pgrep skips its own ancestors.
  local out = run({ "/usr/bin/pgrep", "-a", "-P", tostring(pid), "-x", name })
  return out and tonumber(out:match("%d+"))
end

local function agent_kind(info)
  if is_shell(info.fg) then return nil end
  -- Node programs such as pi report name "node". pi sets argv0 to "pi" a few
  -- seconds after it starts; before that, only the script path names it.
  local name = info.fg.name or ""
  local arg0 = basename(info.fg.argv0)
  local script
  if RUNTIMES[name] or RUNTIMES[arg0] then
    script = basename((info.command or ""):match("^%S+%s+(%S+)"))
  end
  local function is(n)
    return name == n or arg0 == n or script == n or WRAPPERS[name] == n or WRAPPERS[arg0] == n
  end
  if is("claude") or info.app == "claude-code" then return "claude" end
  if is("codex") or (info.app or ""):match("codex") then return "codex" end
  if is("pi") then return "pi" end
  return nil
end

-- Splits argv into the wrapper prefix (kept as is, such as "tcr run --") and
-- the agent's own arguments. Returns an empty prefix when argv[1] is not a
-- wrapper.
local function split_wrapper(argv)
  if not (argv[1] and WRAPPERS[basename(argv[1])]) then return {}, argv end
  local prefix, rest, in_rest = {}, {}, false
  for _, w in ipairs(argv) do
    if in_rest then
      rest[#rest + 1] = w
    else
      prefix[#prefix + 1] = w
      if w == "--" then in_rest = true end
    end
  end
  if not in_rest then prefix[#prefix + 1] = "--" end
  return prefix, rest
end

-- Each agent lookup returns { kind, mode, command, session_id }. mode is
-- "resume" (command resumes session_id), "new" (the session had no messages
-- yet, so command starts a new one), or "picker" (session unknown, command
-- opens the agent's session picker).

-- Claude writes the transcript only after the first message.
local conversations = {}
local function claude_has_conversation(sid)
  if conversations[sid] then return true end
  local found = run({ "/bin/sh", "-c",
    [[for f in "$1"/*/"$2".jsonl; do grep -q -m 1 '"type":"user"' "$f" 2>/dev/null && exit 0; done; exit 1]],
    "sh", CLAUDE_DIR .. "/projects", sid }) ~= nil
  if found then conversations[sid] = true end
  return found
end

local function claude_agent(info)
  local fg = info.fg
  local cpid = fg.name == "claude" and fg.pid or child_named(fg.pid, "claude")
  local session = cpid and read_json(CLAUDE_DIR .. "/sessions/" .. cpid .. ".json")
  local sid = type(session) == "table" and session.sessionId or nil
  local base = args_of(fg.pid)
  if not base then return nil end

  local prefix, rest = split_wrapper(words(base))
  local out = {}
  for _, w in ipairs(prefix) do out[#out + 1] = w end
  local i = 1
  if #prefix == 0 then
    -- Plain claude: drop a version-pinned path so the command survives upgrades.
    out[1] = rest[1]:match("/claude$") and "claude" or rest[1]
    i = 2
  end
  while i <= #rest do
    local w, nxt = rest[i], rest[i + 1]
    if w == "--resume" or w == "-r" or w == "--session-id" then
      if is_id(nxt) then i = i + 1 end
    elseif w:match("^%-%-resume=") or w:match("^%-%-session%-id=")
        or w == "--continue" or w == "-c" or w == "--fork-session" then
      -- dropped
    else
      out[#out + 1] = w
    end
    i = i + 1
  end
  if is_id(sid) and not claude_has_conversation(sid) then
    return { kind = "claude", mode = "new", command = join(out) }
  end
  out[#out + 1] = "--resume"
  if not is_id(sid) then return { kind = "claude", mode = "picker", command = join(out) } end
  out[#out + 1] = sid
  return { kind = "claude", mode = "resume", session_id = sid, command = join(out) }
end

-- Codex keeps its rollout file (sessions/.../rollout-<time>-<id>.jsonl) open.
local function codex_session(pid)
  -- -b: skip calls that can block on a slow mount. -n -P: no name lookups.
  local out = run({ "/usr/sbin/lsof", "-b", "-w", "-n", "-P", "-a", "-p", tostring(pid), "-Fn" }, true)
  for path in (out or ""):gmatch("n([^\n]+)") do
    local id = path:match("/sessions/.*rollout%-.*%-(%x+%-%x+%-%x+%-%x+%-%x+)%.jsonl$")
    if id then return id end
  end
  return nil
end

local function codex_agent(info)
  local fg = info.fg
  local cpid = fg.name == "codex" and fg.pid or child_named(fg.pid, "codex")
  local sid = cpid and codex_session(cpid)
  local base = (WRAPPERS[fg.name] or not cpid) and args_of(fg.pid) or args_of(cpid)
  if not base then return nil end

  local prefix, rest = split_wrapper(words(base))
  local out, drop = {}, {}
  if #prefix > 0 then
    for _, w in ipairs(prefix) do out[#out + 1] = w end
  else
    out = { "codex" }
    for _, ew in ipairs(EXEC_WRAPPERS) do
      if ew.agent == "codex" and base:find(ew.marker, 1, true) then
        out, drop = {}, ew.drop
        for _, w in ipairs(ew.command) do out[#out + 1] = w end
      end
    end
  end
  local i = #prefix > 0 and 1 or 2
  while i <= #rest do
    local w, nxt = rest[i], rest[i + 1]
    if w == "-c" and nxt and starts_with_any(nxt, drop) then
      i = i + 1
    elseif w == "resume" then
      if nxt and (is_id(nxt) or nxt == "--last") then i = i + 1 end
    elseif w ~= "--last" then
      out[#out + 1] = w
    end
    i = i + 1
  end
  -- Codex opens the rollout file at the first message.
  if cpid and not sid then return { kind = "codex", mode = "new", command = join(out) } end
  out[#out + 1] = "resume"
  if not sid then return { kind = "codex", mode = "picker", command = join(out) } end
  out[#out + 1] = sid
  return { kind = "codex", mode = "resume", session_id = sid, command = join(out) }
end

-- pi keeps no session file open. pi-extension.ts writes PI_SESSIONS/<pid>.json
-- with the session, the cwd, and pi's arguments on each session_start.
local function pi_agent(info)
  local session = read_json(PI_SESSIONS .. info.fg.pid .. ".json")
  local argv
  if type(session) == "table" and type(session.args) == "table" then
    argv = { "pi" }
    for _, w in ipairs(session.args) do argv[#argv + 1] = w end
  else
    argv = words(args_of(info.fg.pid))
    if argv[1] and RUNTIMES[basename(argv[1])] then table.remove(argv, 1) end
    if not argv[1] then return nil end
  end
  local out, i = { argv[1]:match("/pi$") and "pi" or argv[1] }, 2
  while i <= #argv do
    local w = argv[i]
    if w == "--session" or w == "--session-id" or w == "--fork" or w == "--name" or w == "-n" then
      i = i + 1
    elseif w ~= "--continue" and w ~= "-c" and w ~= "--resume" and w ~= "-r" then
      out[#out + 1] = w
    end
    i = i + 1
  end
  if type(session) ~= "table" then
    -- pi started before the extension was installed.
    out[#out + 1] = "--resume"
    return { kind = "pi", mode = "picker", command = join(out) }
  end
  -- pi writes the session file only after the first message.
  if not exists(session.sessionFile) then return { kind = "pi", mode = "new", command = join(out) } end
  out[#out + 1] = "--session"
  out[#out + 1] = session.sessionFile
  return { kind = "pi", mode = "resume", session_id = session.sessionId, command = join(out) }
end

local AGENTS = { claude = claude_agent, codex = codex_agent, pi = pi_agent }
local MODE_RANK = { picker = 1, new = 2, resume = 3 }

local function resolve_agent(info)
  info.tried_at = os.time()
  local kind = agent_kind(info)
  if not kind then
    info.agent = nil
    return
  end
  local ok, agent = pcall(AGENTS[kind], info)
  if ok and agent then
    info.agent = agent
  elseif not ok then
    log("agent lookup failed:", agent)
  end
end

-- State updates -------------------------------------------------------------

local function block_info(bid, sid)
  local info = blocks[bid]
  if not info then
    info = {}
    blocks[bid] = info
  end
  if sid then info.session_id = sid end
  return info
end

local function set_foreground(info, fg)
  local old_pid = info.fg and info.fg.pid
  if fg and fg.cwd then info.cwd = fg.cwd end
  if fg and old_pid == fg.pid then
    info.fg = fg
    return
  end
  info.fg = fg
  info.app, info.agent, info.command = nil, nil, nil
  if fg and not is_shell(fg) then
    info.command = args_of(fg.pid)
    resolve_agent(info)
    if info.agent then
      -- Wrappers start the agent a moment later, and agents write their
      -- session files after they start.
      for _, delay in ipairs({ 3, 10 }) do
        rex.after(delay, function()
          if info.fg and info.fg.pid == fg.pid and not info.closed_at then resolve_agent(info) end
        end)
      end
    end
  end
end

local function refresh_process(sid, bid)
  local r = call("block.method", { session_id = sid, block_id = bid, method = "process" })
  if type(r) == "table" and r.foreground then
    set_foreground(block_info(bid, sid), r.foreground)
  end
end

local GONE_SECONDS = 60

local function refresh_view(sid)
  local v = call("session.view", { session_id = sid })
  if type(v) ~= "table" then return end
  local s = { label = v.label, windows = {}, order = {}, gone = {} }
  for _, w in ipairs(v.windows or {}) do
    local tiled
    for _, layer in ipairs(w.layers or {}) do
      if layer.kind == "tiled" then tiled = layer end
    end
    if tiled then
      s.windows[w.window_id] = { label = w.label, focused = w.focused_block_id, layout = tiled.layout, blocks = tiled.blocks or {} }
      s.order[#s.order + 1] = w.window_id
      for _, b in ipairs(tiled.blocks or {}) do
        local info = block_info(b.block_id, sid)
        info.label, info.flavor = b.label, b.flavor
      end
    end
  end
  -- The app can drop a tab from the view before it sends window_closed, so
  -- keep the last view of each removed tab for a while.
  local old = sessions[sid]
  if old then
    local now = os.time()
    for wid, g in pairs(old.gone or {}) do
      if not s.windows[wid] and now - g.at < GONE_SECONDS then s.gone[wid] = g end
    end
    for i, wid in ipairs(old.order) do
      if not s.windows[wid] then
        s.gone[wid] = { window = old.windows[wid], next_id = old.order[i + 1], at = now }
      end
    end
  end
  sessions[sid] = s
end

-- Closed tab records --------------------------------------------------------

local function pane_spec(bid)
  local info = blocks[bid] or {}
  local spec = { label = info.label, cwd = info.cwd, kind = "shell" }
  if info.agent then
    -- Agents are interactive, so start them in every mode.
    spec.kind, spec.agent, spec.mode = "agent", info.agent.kind, info.agent.mode
    spec.agent_session = info.agent.session_id
    spec.input = info.agent.command .. "\n"
  elseif not is_shell(info.fg) and info.command then
    -- Typed without Enter: the user decides whether to run it again.
    spec.kind, spec.input = "command", info.command
  end
  return spec
end

local function convert(node, panes, focused, focus)
  if node.block_id then
    local spec = pane_spec(node.block_id)
    panes[#panes + 1] = spec
    if node.block_id == focused then focus.index = #panes end
    local flavor = (blocks[node.block_id] or {}).flavor
    if not flavor or not flavor:match("^com%.superlogical%.terminal%.") then flavor = SHELL_FLAVOR end
    local options = {}
    if spec.cwd then options.cwd = spec.cwd end
    if spec.input then options.initial_input = spec.input end
    return { block = { flavor = flavor, label = spec.label, options = options } }
  end
  local split = node.split
  return {
    split = {
      direction = split.direction,
      ratio = split.ratio,
      before = convert(split.before, panes, focused, focus),
      after = convert(split.after, panes, focused, focus),
    },
  }
end

local function record_closed(sid, wid)
  local s = sessions[sid]
  if not s then
    log("skipped", wid, "in", sid, ": session not tracked")
    return
  end
  local w, next_id = s.windows[wid], nil
  if w then
    for i, id in ipairs(s.order) do
      if id == wid then next_id = s.order[i + 1] end
    end
  elseif s.gone[wid] then
    w, next_id = s.gone[wid].window, s.gone[wid].next_id
    s.gone[wid] = nil
  end
  if not w or not w.layout then
    log("skipped", wid, "in", s.label or sid, ": tab not in the cached view")
    return
  end

  -- A program exit sends child_exited before block_closed. Closing the last
  -- pane sends block_closed before window_closed, with no child_exited.
  local alive = false
  for _, b in ipairs(w.blocks) do
    local info = blocks[b.block_id]
    if not (info and info.exited_at) then alive = true end
  end
  if not alive then -- the program exited and closed the tab
    log("skipped", wid, "in", s.label or sid, ": program exited")
    return
  end

  -- Look one last time. The server can remove the panes before window_closed,
  -- so the pane call can fail while the agent process still runs.
  for _, b in ipairs(w.blocks) do
    local info = blocks[b.block_id]
    local r = info and call("block.method", { session_id = sid, block_id = b.block_id, method = "process" })
    if type(r) == "table" and r.foreground and info.fg and r.foreground.pid == info.fg.pid then
      info.cwd = r.foreground.cwd or info.cwd
    end
    if info and info.agent and info.fg and run({ "/bin/kill", "-0", tostring(info.fg.pid) }) then
      -- An agent that is already exiting can lose its session files: keep
      -- the better of the old and the new lookup.
      local old = info.agent
      resolve_agent(info)
      if (MODE_RANK[old.mode] or 0) > (MODE_RANK[info.agent and info.agent.mode] or 0) then info.agent = old end
    end
  end

  local panes, focus = {}, {}
  local layout = convert(w.layout, panes, w.focused, focus)
  local label = w.label
  if label and label:match("^Window %x+$") then label = nil end

  local tabs = load_tabs()
  tabs[#tabs + 1] = {
    id = wid,
    session_id = sid,
    session_label = s.label,
    label = label,
    closed_at = os.time(),
    next_window_id = next_id,
    focus = focus.index,
    layout = layout,
    panes = panes,
  }

  local kept, count = {}, {}
  for i = #tabs, 1, -1 do
    local t = tabs[i]
    count[t.session_id] = (count[t.session_id] or 0) + 1
    if count[t.session_id] <= MAX_PER_SESSION then table.insert(kept, 1, t) end
  end
  save_tabs(kept)

  local kinds = {}
  for _, p in ipairs(panes) do kinds[#kinds + 1] = p.agent and (p.agent .. ":" .. (p.mode or "?")) or p.kind end
  log("recorded", wid, "in", s.label or sid, "panes:", table.concat(kinds, ","))
end

-- Events ----------------------------------------------------------------------

-- Handlers and timers run one at a time: log any that holds the others back.
local function timed(label, fn)
  return function(ctx, ev)
    local started = os.time()
    local ok, err = pcall(fn, ctx, ev)
    if not ok then log(label, "failed:", err) end
    local secs = os.time() - started
    if secs >= 2 then
      log("slow handler:", secs, "s:", label, type(ev) == "table" and (ev.name or ev.window_id or ev.block_id) or "")
    end
  end
end

rex.on("session_view_changed", timed("session_view_changed", function(_, ev)
  refresh_view(ev.session_id)
end))

rex.on("window_closed", timed("window_closed", function(_, ev)
  record_closed(ev.session_id, ev.window_id)
end))

rex.on("block_closed", timed("block_closed", function(_, ev)
  block_info(ev.block_id).closed_at = os.time()
end))

rex.on("block_event", timed("block_event", function(_, ev)
  local info = block_info(ev.block_id, ev.session_id)
  if ev.name == "process_changed" then
    set_foreground(info, ev.payload and ev.payload.foreground)
  elseif ev.name == "child_exited" then
    info.exited_at = os.time()
  elseif ev.name == "program_status_changed" then
    local rec = ev.payload and ev.payload.record
    if rec then info.app = rec.effective_app or rec.app end
    -- Agents write their session file after they start, and /clear starts a new session.
    local pending = info.agent and info.agent.mode ~= "resume"
    if pending or os.time() - (info.tried_at or 0) >= 10 then resolve_agent(info) end
  end
end))

local function refresh_all()
  local now = os.time()
  local list = call("session.list", {})
  for _, sess in ipairs(type(list) == "table" and list.sessions or {}) do
    if not sessions[sess.session_id] then refresh_view(sess.session_id) end
  end
  -- pi removes its file on a normal exit, but not when a closed tab kills it.
  for file in (run({ "/bin/ls", PI_SESSIONS }) or ""):gmatch("[^\n]+") do
    local pid = file:match("^(%d+)%.json$")
    if pid and not run({ "/bin/kill", "-0", pid }) then os.remove(PI_SESSIONS .. file) end
  end
  for bid, info in pairs(blocks) do
    if info.closed_at then
      if now - info.closed_at > 120 then blocks[bid] = nil end
    elseif info.session_id then
      refresh_process(info.session_id, bid)
      if agent_kind(info) and now - (info.tried_at or 0) >= REFRESH_SECONDS then resolve_agent(info) end
    end
  end
end

run({ "/bin/mkdir", "-p", (STATE:gsub("/[^/]*$", "")) })
-- With --all, the script can read a session only after this file finishes loading.
rex.after(1, timed("startup scan", refresh_all))
rex.every(REFRESH_SECONDS, timed("refresh", refresh_all))
-- Agents with no session yet: look again often, so a first message counts
-- even when the tab closes soon after it.
rex.every(10, timed("pending agents", function()
  for _, info in pairs(blocks) do
    if info.agent and info.agent.mode ~= "resume" and not info.closed_at then resolve_agent(info) end
  end
end))
log("tracking", STATE)
