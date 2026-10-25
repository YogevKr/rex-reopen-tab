-- Close-order cases for tracker.lua. rex.call is stubbed, so no session is
-- touched. Run by test/run.sh with: tracker=PATH out=PATH
local handlers = {}
rex.on = function(name, fn) handlers[name] = fn end
rex.every = function() end
rex.after = function() end
rex.args.state = rex.args.out

local S = "session:test"
local function win(n)
  return {
    window_id = "window:" .. n, label = "Window " .. n, focused_block_id = "block:" .. n,
    layers = { {
      kind = "tiled",
      layout = { block_id = "block:" .. n },
      blocks = { { block_id = "block:" .. n, label = "shell", flavor = "com.superlogical.terminal.shell" } },
    } },
  }
end
local view
rex.call = function(method)
  if method == "session.view" then return view end
  if method == "session.list" then return { sessions = {} } end
  error("no " .. method)
end

dofile(rex.args.tracker)

local function view_changed() handlers.session_view_changed(nil, { session_id = S }) end
local function closed(n) handlers.window_closed(nil, { session_id = S, window_id = "window:" .. n }) end

view = { label = "test", windows = { win("a"), win("b"), win("c"), win("d") } }
view_changed()
handlers.block_event(nil, { session_id = S, block_id = "block:b", name = "process_changed",
  payload = { foreground = { pid = 1, name = "zsh", cwd = "/usr/local" } } })

-- 1. The app drops tab b from the view before window_closed.
view = { label = "test", windows = { win("a"), win("c"), win("d") } }
view_changed()
closed("b")
-- 2. Tab a closes while it is still in the view.
closed("a")
-- 3. An unknown tab.
closed("zz")
-- 4. The program in tab c exits.
handlers.block_event(nil, { session_id = S, block_id = "block:c", name = "child_exited", payload = { exit_code = 0 } })
handlers.block_closed(nil, { session_id = S, block_id = "block:c" })
closed("c")
-- 5. The last pane of tab d closes: block_closed comes first, no child_exited.
handlers.block_closed(nil, { session_id = S, block_id = "block:d" })
closed("d")

local f = assert(io.open(rex.args.out, "r"))
local tabs = rex.json.decode(f:read("*a")).tabs
f:close()
local by_id = {}
for _, t in ipairs(tabs) do by_id[t.id] = t end

local failures = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end
check("dropped from view, then closed: recorded", by_id["window:b"] ~= nil)
check("dropped tab keeps its folder", by_id["window:b"] and by_id["window:b"].panes[1].cwd == "/usr/local")
check("dropped tab keeps its position", by_id["window:b"] and by_id["window:b"].next_window_id == "window:c")
check("tab closed in view: recorded", by_id["window:a"] ~= nil)
check("unknown tab: not recorded", by_id["window:zz"] == nil)
check("program exited: not recorded", by_id["window:c"] == nil)
check("last pane closed: recorded", by_id["window:d"] ~= nil)
check("record count", #tabs == 3)
rex.stop(failures == 0 and 0 or 1)
