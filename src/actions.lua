-- rex-reopen-tab actions: rebuild the tabs that tracker.lua records.
--
-- Load from init.lua:
--   dofile("/path/to/actions.lua"){}   (install.sh adds this line)
-- Options: state = path of the closed-tabs file, key = binding ("" for none).

return function(opts)
  opts = opts or {}
  local HOME = os.getenv("HOME")
  local STATE = opts.state or (HOME .. "/.local/state/rex-reopen-tab/closed-tabs.json")
  local KEY = opts.key or "cmd+shift+t"
  local LOG = STATE:gsub("[^/]*$", "") .. "actions.log"

  -- One line per run, so a key press that seems to do nothing leaves a trace.
  local function log_run(name, ctx, result)
    local f = io.open(LOG, "a")
    if not f then return end
    local fields = {}
    if type(ctx) == "table" then
      for k, v in pairs(ctx) do
        if type(v) == "string" or type(v) == "number" then fields[#fields + 1] = k .. "=" .. tostring(v) end
      end
    end
    table.sort(fields)
    local ok, text = pcall(rex.json.encode, result)
    f:write(os.date("%Y-%m-%d %H:%M:%S "), name, " ", table.concat(fields, " "), " -> ", ok and text or tostring(result), "\n")
    f:close()
  end

  local function load_tabs()
    local f = io.open(STATE, "r")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(rex.json.decode, text)
    if ok and type(data) == "table" and type(data.tabs) == "table" then return data.tabs end
    return {}
  end

  local function save_tabs(tabs)
    local tmp = STATE .. ".tmp"
    local f = assert(io.open(tmp, "w"))
    if #tabs == 0 then
      f:write('{"version":1,"tabs":[]}')
    else
      f:write(rex.json.encode({ version = 1, tabs = tabs }))
    end
    f:close()
    assert(os.rename(tmp, STATE))
  end

  -- Indexes of the tabs closed in session sid (or in every session), newest first.
  local function matching(tabs, sid, any)
    local out = {}
    for i = #tabs, 1, -1 do
      if any or tabs[i].session_id == sid then out[#out + 1] = i end
    end
    return out
  end

  local function summary(tab)
    local parts = {}
    for _, p in ipairs(tab.panes or {}) do
      local what = p.kind
      if p.kind == "agent" then
        what = p.agent .. " " .. (p.mode == "resume" and p.agent_session or p.mode or p.agent_session or "")
      end
      parts[#parts + 1] = what .. " in " .. (p.cwd or "~")
    end
    return {
      label = tab.label,
      session = tab.session_label or tab.session_id,
      closed_at = os.date("%Y-%m-%d %H:%M:%S", tab.closed_at or 0),
      panes = parts,
    }
  end

  local ARGS = {
    type = "object",
    properties = {
      index = { type = "integer", description = "Which closed tab to reopen: 1 is the most recent." },
      any = { type = "boolean", description = "Also reopen tabs closed in other sessions, into this session." },
    },
  }

  local function reopen(ctx, args)
    args = args or {}
    local sid = ctx.session_id
    local tabs = load_tabs()
    local found = matching(tabs, sid, args.any)
    local pick = found[tonumber(args.index) or 1]
    -- An error, not a result, so the app can show it.
    if not pick then error("No closed tab to reopen in this session", 0) end

    local tab = tabs[pick]
    local created, err = rex.call("session.new_window", {
      session_id = sid,
      layout = tab.layout,
      window_label = tab.label,
    })
    if type(created) ~= "table" then error("Cannot reopen the tab: " .. tostring(err), 0) end
    table.remove(tabs, pick)
    -- Tabs closed before this one keep their place next to its new ID.
    for _, t in ipairs(tabs) do
      if t.next_window_id == tab.id then t.next_window_id = created.window_id end
    end
    save_tabs(tabs)

    if tab.next_window_id then
      pcall(rex.call, "session.move_window", {
        session_id = sid,
        window_id = created.window_id,
        before_window_id = tab.next_window_id,
      })
    end
    local focus = tab.focus and created.block_ids[tab.focus]
    if focus and tab.focus > 1 then
      pcall(rex.call, "session.focus_block", { session_id = sid, block_id = focus })
    end
    local result = summary(tab)
    result.reopened, result.window_id = true, created.window_id
    return result
  end

  rex.action({
    name = "reopen_closed_tab",
    title = "Reopen Closed Tab",
    description = "Open the most recently closed tab again, with its panes, folders, and resumed agents.",
    category = "Tabs",
    keywords = "undo restore close tab history",
    args = ARGS,
    run = function(ctx, args)
      local ok, result = pcall(reopen, ctx, args)
      log_run("reopen_closed_tab", ctx, ok and result or { error = tostring(result) })
      if not ok then error(result, 0) end
      return result
    end,
  })

  rex.action({
    name = "list_closed_tabs",
    title = "List Closed Tabs",
    description = "Show the tabs that Reopen Closed Tab can open again, newest first.",
    category = "Tabs",
    args = ARGS,
    run = function(ctx, args)
      args = args or {}
      local tabs = load_tabs()
      local out = {}
      for n, i in ipairs(matching(tabs, ctx.session_id, args.any)) do
        local s = summary(tabs[i])
        s.index = n
        out[#out + 1] = s
      end
      return { tabs = out }
    end,
  })

  if KEY ~= "" then rex.bind(KEY, "reopen_closed_tab") end
end
