--!strict
-- Host half. Two blocks:
--
--   periscope.list        the sub-agents of the omp session that runs in this block's
--                         directory, with live status. Click (or Enter) opens one's
--                         transcript in this same block; Esc, or Left twice, returns to
--                         the list. Cmd+click (Cmd+Enter) opens the transcript in a
--                         periscope.transcript block below instead.
--   periscope.transcript  one transcript, live, as its own block.
--
-- Everything comes from omp's own session files; see lib/agents.luau and scripts/scan.sh.

local ui = tern.ui
local util = require("./lib/util")
local agents = require("./lib/agents")
local transcript = require("./lib/transcript")

type Agent = agents.Agent
type Session = agents.Session
type Viewer = transcript.Viewer

local TICK_MS = 1500 -- loop period; the agent scan runs every REFRESH_EVERY ticks
local REFRESH_EVERY = 2
local SESSIONS_EVERY = 6 -- re-list the directory's sessions this often (in ticks)

-- Whether pane `pane` still runs (a block that ended is gone from the list).
local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function safe(s: string): string
	local out = string.gsub(s, "[^%w_%-]", "_")
	return out
end

local function has(list: any, value: string): boolean
	if type(list) == "table" then
		for _, v in list do
			if v == value then
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------------------------------
-- periscope.list
------------------------------------------------------------------------------------------

type ListState = {
	cwd: string?,
	bucket: string?,
	sessions: { Session },
	pinned: string?, -- session id chosen with `s`/the picker; nil follows `want`, then the newest
	want: string?, -- title of the omp session running in the tab this block opened from (agents.title_key)
	session: Session?,
	agents: { [string]: Agent },
	sizes: { [string]: number },
	now: number, -- epoch ms at the last scan
	mono: number, -- tern.now() at the last scan
	ticks: number,
	busy: boolean,
	stopped: boolean,
	loaded: boolean,
	error: string?,
	sel: string?, -- file name of the selected agent
	filter: string, -- all | running | error | finished
	layout: string, -- list | split (picker on top, one transcript below, in this block)
	viewing: string?, -- file name of the agent whose transcript fills the block
	viewer: Viewer?,
	viewers: { [string]: Viewer }, -- by transcript path: reopening an agent keeps its output mode, folds and cursor
	restore: string?, -- transcript to reopen once the session is known
	skip_empty: boolean, -- hide sessions that have no subagents
	picking: boolean, -- the session picker popup is open
}

local function wall(state: ListState): number
	return state.now + (tern.now() - state.mono)
end

-- Shown status: a "running" agent that has been silent for STALE_MS reads as idle.
local function shown(state: ListState, a: Agent): string
	if a.status == "running" and a.last ~= nil and wall(state) - a.last > agents.STALE_MS then
		return "idle"
	end
	return a.status
end

local RANK: { [string]: number } = { running = 1, pending = 2, idle = 3, failed = 4, aborted = 4, parked = 5 }

local function ordered(state: ListState): { Agent }
	local list: { Agent } = {}
	for _, a in state.agents do
		table.insert(list, a)
	end
	table.sort(list, function(x, y)
		local rx, ry = RANK[shown(state, x)] or 9, RANK[shown(state, y)] or 9
		if rx ~= ry then
			return rx < ry
		end
		local lx, ly = x.last or 0, y.last or 0
		if lx ~= ly then
			return lx > ly
		end
		return x.name < y.name
	end)
	return list
end

local FILTERS = {
	{ id = "all", label = "All" },
	{ id = "running", label = "Running" },
	{ id = "error", label = "Error" },
	{ id = "finished", label = "Finished" },
}

-- Filter group of each shown status; the "all" filter matches everything.
local GROUP: { [string]: string } = {
	running = "running",
	pending = "running",
	failed = "error",
	aborted = "error",
	idle = "finished",
	parked = "finished",
}

local function valid_filter(id: any): boolean
	for _, f in FILTERS do
		if f.id == id then
			return true
		end
	end
	return false
end

-- The agents the current filter lists, in display order.
local function visible(state: ListState): { Agent }
	local out: { Agent } = {}
	for _, a in ordered(state) do
		if state.filter == "all" or GROUP[shown(state, a)] == state.filter then
			table.insert(out, a)
		end
	end
	return out
end

-- Keeps the selection on a listed agent: the first row when it is unset or filtered out.
local function ensure_sel(state: ListState)
	local rows = visible(state)
	for _, a in rows do
		if a.file == state.sel then
			return
		end
	end
	state.sel = if rows[1] ~= nil then rows[1].file else nil
end

local function merge(state: ListState, name: string, d: agents.Digested, init: agents.Init?)
	local a: Agent = state.agents[name]
		or {
			name = util.strip_suffix(name, ".jsonl"),
			file = name,
			size = 0,
			tools = 0,
			requests = 0,
			cost = 0,
			tokens = 0,
			status = "pending",
		}
	if init ~= nil then
		a.agent_kind, a.model, a.task = init.agent_kind, init.model, init.task
	end
	local activity = agents.classify(d.digests)
	a.tools, a.requests, a.cost, a.tokens = d.tools, d.requests, d.cost, d.tokens
	a.started = d.started or a.started
	a.status, a.tool, a.intent, a.tool_started, a.last = activity.status, activity.tool, activity.intent, activity.tool_started, activity.last
	a.size = state.sizes[name] or a.size
	state.agents[name] = a
end

local function chunks(names: { string }, n: number): { { string } }
	local out: { { string } } = {}
	for i = 1, #names, n do
		local chunk: { string } = {}
		for j = i, math.min(i + n - 1, #names) do
			table.insert(chunk, names[j])
		end
		table.insert(out, chunk)
	end
	return out
end

-- The sessions the picker, `s` and `S` can reach: all of them, or only those with subagents.
local function listed(state: ListState): { Session }
	if not state.skip_empty then
		return state.sessions
	end
	local out: { Session } = {}
	for _, s in state.sessions do
		if s.subagents > 0 then
			table.insert(out, s)
		end
	end
	return out
end

local open_here: (state: ListState, file: string, cx: BlockCx) -> ()

-- Looks at the session store and updates state; `done` runs when the scan is finished.
local function scan(state: ListState, cx: BlockCx, done: () -> ())
	local function fail(err: string?)
		state.error = err or "scan failed"
		done()
	end

	local function scan_agents()
		local session = state.session
		if session == nil or not tern.fs.exists(session.dir) then
			state.agents, state.sizes = {}, {}
			done()
			return
		end
		util.scan({ "sizes", session.dir }, function(out, err)
			if out == nil then
				return fail(err)
			end
			local sizes, now = agents.parse_sizes(out)
			if now ~= nil then
				state.now, state.mono = now, tern.now()
			end
			local changed: { string } = {}
			local fresh: { string } = {}
			for name, size in sizes do
				if state.sizes[name] ~= size or state.agents[name] == nil then
					table.insert(changed, name)
				end
				if state.agents[name] == nil then
					table.insert(fresh, name)
				end
			end
			for name in state.agents do
				if sizes[name] == nil then
					state.agents[name] = nil
				end
			end
			state.sizes = sizes
			state.error = nil
			if #changed == 0 then
				done()
				return
			end
			table.sort(changed)
			local pending = 0
			local inits: { [string]: agents.Init } = {}
			local digests: { [string]: agents.Digested } = {}
			local function joined()
				pending -= 1
				if pending > 0 then
					return
				end
				for name, d in digests do
					merge(state, name, d, inits[name])
				end
				if state.restore ~= nil and state.agents[state.restore] ~= nil then
					local file = state.restore
					state.restore = nil
					open_here(state, file, cx)
				end
				done()
			end
			for _, group in chunks(fresh, 40) do
				pending += 1
				local args = { "init", session.dir }
				for _, n in group do
					table.insert(args, n)
				end
				util.scan(args, function(init_out)
					if init_out ~= nil then
						for name, init in agents.parse_inits(init_out) do
							inits[name] = init
						end
					end
					joined()
				end)
			end
			for _, group in chunks(changed, 40) do
				pending += 1
				local args = { "agent", session.dir }
				for _, n in group do
					table.insert(args, n)
				end
				util.scan(args, function(agent_out, agent_err)
					if agent_out ~= nil then
						for name, d in agents.parse_digests(agent_out) do
							digests[name] = d
						end
					else
						state.error = agent_err
					end
					joined()
				end)
			end
		end)
	end

	local bucket = state.bucket
	if bucket == nil then
		state.error = "Cannot locate omp's session directory (no HOME)"
		done()
		return
	end
	if state.ticks % SESSIONS_EVERY ~= 0 and state.session ~= nil then
		scan_agents()
		return
	end
	util.scan({ "sessions", bucket }, function(out, err)
		if out == nil then
			return fail(err)
		end
		local sessions, now = agents.parse_sessions(out, bucket)
		if now ~= nil then
			state.now, state.mono = now, tern.now()
		end
		state.sessions = sessions
		local choices = listed(state)
		local pick: Session? = choices[1]
		if state.pinned == nil and state.want ~= nil then
			for _, s in choices do
				if agents.title_key(s.title) == state.want then
					pick = s
					break
				end
			end
		end
		if state.pinned ~= nil then
			for _, s in choices do
				if s.id == state.pinned then
					pick = s
				end
			end
		end
		local previous = state.session
		if previous ~= nil and (pick == nil or previous.id ~= pick.id) then
			state.agents, state.sizes = {}, {}
			state.sel = nil
			state.viewing, state.viewer = nil, nil
		end
		state.session = pick
		scan_agents()
	end)
end

local function title_of(state: ListState): string
	local n = 0
	for _, a in state.agents do
		if shown(state, a) == "running" then
			n += 1
		end
	end
	if state.viewing ~= nil then
		return util.strip_suffix(state.viewing, ".jsonl")
	end
	return if n > 0 then "Periscope (" .. n .. " running)" else "Periscope"
end

function open_here(state: ListState, file: string, cx: BlockCx)
	local session = state.session
	if session == nil then
		return
	end
	local a = state.agents[file]
	local path = session.dir .. "/" .. file
	local v = state.viewers[path]
	if v == nil then
		v = transcript.new(path, if a ~= nil then a.name else file)
		state.viewers[path] = v
	end
	state.viewing, state.viewer, state.sel = file, v, file
	transcript.poll(v, true, function()
		cx:render()
		if v.follow or v.land then
			transcript.follow_soon(v, cx)
		else
			transcript.restore_soon(v, cx)
		end
	end)
end

local function row_id(state: ListState, a: Agent): string
	if state.layout == "split" then
		return "layer.picker.rows.a_" .. safe(a.name)
	end
	return "main.body.agents.a_" .. safe(a.name)
end

-- Scrolls the list to the selected row. `later` waits a beat for rows that were just mounted.
local function reveal(state: ListState, cx: BlockCx, later: boolean)
	local file = state.sel
	local a = if file ~= nil then state.agents[file] else nil
	if a == nil then
		return
	end
	local id = row_id(state, a)
	if not later then
		cx:frame({ { "reveal", id, "nearest" } })
		return
	end
	tern.timer(60, function()
		if (state.layout == "split" or state.viewer == nil) and running(cx.pane) then
			cx:frame({ { "reveal", id, "nearest" } })
		end
	end)
end

local function close_view(state: ListState, cx: BlockCx)
	state.viewing, state.viewer = nil, nil
	reveal(state, cx, true)
end

-- Opens `file` in the transcript below the picker (nothing happens if it is already there).
local function open_split(state: ListState, file: string, cx: BlockCx)
	if state.viewing == file and state.viewer ~= nil then
		return
	end
	open_here(state, file, cx)
end

-- Keeps the split view's transcript on the selected agent.
local function sync_split(state: ListState, cx: BlockCx)
	if state.layout ~= "split" then
		return
	end
	if state.sel ~= nil then
		open_split(state, state.sel, cx)
	else
		state.viewing, state.viewer = nil, nil
	end
end

-- Shows session `nxt`: pins it, drops the old session's agents and rescans.
local function switch_session(state: ListState, nxt: Session, cx: BlockCx)
	local current = state.session
	if current ~= nil and current.id == nxt.id then
		return
	end
	state.pinned = nxt.id
	state.session, state.agents, state.sizes, state.sel = nxt, {}, {}, nil
	state.viewing, state.viewer = nil, nil
	state.ticks = 1 -- next tick is not a session re-list
	scan(state, cx, function()
		ensure_sel(state)
		sync_split(state, cx)
		cx:render()
	end)
	cx:render()
end

-- Moves to the previous (-1) or next (1) listed agent, in the split view's transcript or the drill-down.
local function step_agent(state: ListState, dir: number, cx: BlockCx)
	local order = visible(state)
	local at = 0
	for i, ag in order do
		if ag.file == (state.viewing or state.sel) then
			at = i
		end
	end
	local nxt = order[math.max(1, math.min(at + dir, #order))]
	if nxt == nil or nxt.file == state.viewing then
		return
	end
	state.sel = nxt.file
	if state.layout == "split" then
		open_split(state, nxt.file, cx)
	else
		open_here(state, nxt.file, cx)
	end
	reveal(state, cx, true)
end

-- `dir` 1: the next session in the list (older), -1: the previous one (newer); wraps around.
local function step_session(state: ListState, dir: number, cx: BlockCx)
	local choices = listed(state)
	local n = #choices
	if n < 2 then
		return
	end
	local at = 0
	local current = state.session
	for i, s in choices do
		if current ~= nil and s.id == current.id then
			at = i
		end
	end
	local to = if at == 0 then (if dir > 0 then 1 else n) else (at - 1 + dir) % n + 1
	switch_session(state, choices[to], cx)
end

-- Re-lists the sessions now (after the "hide sessions without subagents" option changed).
local function relist(state: ListState, cx: BlockCx)
	state.ticks = 0
	scan(state, cx, function()
		ensure_sel(state)
		sync_split(state, cx)
		cx:render()
	end)
end

local function set_filter(state: ListState, id: string, cx: BlockCx)
	state.filter = id
	ensure_sel(state)
	sync_split(state, cx)
	reveal(state, cx, true)
end

local function next_filter(state: ListState): string
	local at = 1
	for i, f in FILTERS do
		if f.id == state.filter then
			at = i
		end
	end
	return FILTERS[at % #FILTERS + 1].id
end

local function set_layout(state: ListState, mode: string, cx: BlockCx)
	if mode == state.layout or (mode ~= "list" and mode ~= "split") then
		return
	end
	state.layout = mode
	if mode == "split" then
		ensure_sel(state)
		sync_split(state, cx)
	else
		state.viewing, state.viewer = nil, nil
	end
	reveal(state, cx, true)
end

local function open_below(state: ListState, file: string, cx: BlockCx)
	local session = state.session
	if session == nil then
		return
	end
	local a = state.agents[file]
	local label = if a ~= nil then a.name else util.strip_suffix(file, ".jsonl")
	cx:open("tern-periscope://transcript?path=" .. util.encode(session.dir .. "/" .. file) .. "&label=" .. util.encode(label))
end

-- 12345 -> "12K", 1234567 -> "1.2M".
local function compact(n: number): string
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.0fK", n / 1000)
	end
	return tostring(n)
end

local GLYPH: { [string]: string } = { running = "●", failed = "✕", aborted = "⊘", done = "✓" }

-- One list entry: a single line of nine cells at fixed columns (see periscope.css). Every cell is
-- always present, blank when it has nothing, so a missing stat never shifts the ones after it:
--   status · name · mode (the agent definition) · model · tools · requests · tokens · cost · time
local function agent_node(state: ListState, a: Agent): Node
	local status = shown(state, a)
	local function cell(text: string, style: string?, role: string?): Node
		return with(ui.text({ ui.span(text, style) }), { role = role })
	end
	local took: string = ""
	if a.started ~= nil then
		local to = if status == "running" then wall(state) else a.last
		if to ~= nil then
			took = util.duration(math.max(0, to - a.started))
		end
	end
	-- last "/" segment without the "claude-" vendor prefix: "anthropic/claude-sonnet-5-5" -> "sonnet-5-5"
	local model = if a.model ~= nil then string.gsub(string.match(a.model, "([^/]*)$") or a.model, "^claude%-", "") else ""
	local mode: Node = if a.agent_kind ~= nil then ui.badge(a.agent_kind, "neutral") else cell("")
	return with(
		ui.row({
			with(ui.text({ ui.span(GLYPH[status] or "○") }), { role = "periscope.glyph", mark = status }),
			cell(a.name, "strong", "periscope.name"),
			mode,
			cell(model, "muted", "periscope.model"),
			cell(if a.tools > 0 then tostring(a.tools) .. " tools" else "", "muted", "periscope.num"),
			cell(if a.requests > 0 then a.requests .. " req" else "", "muted", "periscope.num"),
			cell(if a.tokens > 0 then compact(a.tokens) else "", "muted", "periscope.num"),
			cell(if a.cost > 0 then string.format("$%.2f", a.cost) else "", "muted", "periscope.num"),
			cell(took, "dim", "periscope.num"),
		}),
		{
			key = "a_" .. safe(a.name),
			role = "periscope.row",
			mark = if state.sel == a.file then "pick" else nil,
			actions = { click = "open=" .. a.file },
		}
	)
end

-- Agents per filter group, and the total under "all".
local function counts(state: ListState): { [string]: number }
	local n: { [string]: number } = { all = 0, running = 0, error = 0, finished = 0 }
	for _, a in state.agents do
		n.all += 1
		local group = GROUP[shown(state, a)]
		if group ~= nil then
			n[group] += 1
		end
	end
	return n
end

local function filter_badges(state: ListState, n: { [string]: number }): { Node }
	-- the gap grows, pushing the buttons (and anything after them) to the right edge
	local out: { Node } = { with(ui.text({ ui.span("") }), { grow = 1, key = "gap" }) }
	for _, f in FILTERS do
		local on = state.filter == f.id
		table.insert(
			out,
			with(ui.badge(f.label .. " " .. n[f.id], if on then "accent" else "neutral"), {
				key = "filter_" .. f.id,
				role = "periscope.filter",
				actions = { click = "filter=" .. f.id },
				mark = if on then "on" else nil,
			})
		)
	end
	return out
end

local function layout_badge(label: string, mode: string): Node
	return with(ui.badge(label, "neutral"), { key = "layout", role = "periscope.filter", actions = { click = "layout=" .. mode } })
end

-- The "Sessions N" button that opens the session picker.
local function sessions_badge(state: ListState): Node
	return with(ui.badge("Sessions " .. #listed(state), if state.picking then "accent" else "neutral"), {
		key = "sessions",
		role = "periscope.filter",
		actions = { click = "sessions=open" },
		mark = if state.picking then "on" else nil,
	})
end

-- The session picker: a scrollable list drawn in the layer region, over the top of the block.
local function session_popup(state: ListState): Node
	local current = state.session
	local rows: { Node } = {}
	for _, s in listed(state) do
		local on = current ~= nil and current.id == s.id
		local title = if s.title ~= "" then s.title else s.id
		table.insert(
			rows,
			with(
				ui.row({
					with(ui.text({ ui.span(if on then "●" else "○") }), { role = "periscope.glyph", mark = if on then "running" else nil }),
					with(ui.text({ ui.span(title, "strong") }), { role = "periscope.name" }),
					ui.text({ ui.span(s.subagents .. (if s.subagents == 1 then " agent" else " agents"), "muted") }),
				}),
				{
					key = "s_" .. safe(s.id),
					role = "periscope.session",
					mark = if on then "pick" else nil,
					actions = { click = "session=" .. s.id },
				}
			)
		)
	end
	if #rows == 0 then
		table.insert(rows, ui.text({ ui.span(if state.skip_empty then "No session has subagents." else "No omp sessions found.", "muted") }))
	end
	local head = ui.row({
		ui.text({ ui.span("Sessions", "strong") }),
		with(ui.text({ ui.span("") }), { grow = 1, key = "gap" }),
		with(ui.badge("Hide sessions without subagents", if state.skip_empty then "accent" else "neutral"), {
			key = "skip_empty",
			role = "periscope.filter",
			actions = { click = "sessions=skip_empty" },
			mark = if state.skip_empty then "on" else nil,
		}),
		with(ui.badge("Close", "neutral"), { key = "close", role = "periscope.filter", actions = { click = "sessions=close" } }),
	})
	return with(ui.col({ head, with(ui.col(rows), { key = "sessions", role = "periscope.sessions" }) }), { key = "popup", role = "periscope.popup" })
end

-- Draws the session picker above `view` when it is open.
local function with_popup(state: ListState, view: BlockView): BlockView
	if not state.picking then
		return view
	end
	local popup = session_popup(state)
	local below = view.layer
	view.layer = with(ui.col(if below ~= nil then { below, popup } else { popup }), { role = "periscope.layer" })
	return view
end

local function list_view(state: ListState): BlockView
	local n = counts(state)
	local session = state.session
	local head: { Span } = { ui.span("Periscope", "strong") }
	if session ~= nil and session.title ~= "" then
		table.insert(head, ui.span("  " .. session.title, "muted"))
	end
	local bar: { Node } = { ui.text(head) }
	for _, b in filter_badges(state, n) do
		table.insert(bar, b)
	end
	table.insert(bar, sessions_badge(state))
	table.insert(bar, layout_badge("Split view", "split"))
	local header = ui.row(bar)
	local body: { Node } = {}
	if state.error ~= nil then
		table.insert(body, ui.text({ ui.span("Scan failed: ", "error"), ui.span(state.error, "muted") }))
	elseif not state.loaded then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("Reading omp sessions", "muted") } }))
	elseif session == nil then
		table.insert(body, ui.text({ ui.span("No omp session found for " .. (state.cwd or "this directory"), "muted") }))
		table.insert(body, ui.text({ ui.span("Start omp here and its subagents will show up.", "dim") }))
	elseif n.all == 0 then
		table.insert(body, ui.text({ ui.span("No subagents in this session yet.", "muted") }))
	end
	local rows: { Node } = {}
	for _, a in visible(state) do
		table.insert(rows, agent_node(state, a))
	end
	if #rows == 0 and n.all > 0 then
		table.insert(body, ui.text({ ui.span("No " .. string.lower(state.filter) .. " subagents.", "muted") }))
	end
	table.insert(body, with(ui.col(rows), { key = "agents", role = "periscope.panel" }))
	local hint = "↑↓ select · click / enter open here · ⌘click / ⌘enter / o open below · l split view · f filter"
	if #listed(state) > 1 then
		hint ..= " · s/S next/previous session"
	end
	return {
		main = ui.col({ header, with(ui.col(body), { key = "body" }) }),
		dock = ui.row({ ui.text({ ui.span(hint, "muted") }) }),
	}
end

-- A header block: the control bar, then (when there is one) the agent's short task description on
-- its own line, ellipsized. `role` marks the whole block (the drawn header, or the invisible copy).
local function header_block(bar: () -> { Node }, desc: string?, role: string?): Node
	local kids: { Node } = { with(ui.row(bar()), { role = "periscope.bar", key = "bar" }) }
	if desc ~= nil and desc ~= "" then
		table.insert(kids, with(ui.text({ ui.span(desc, "muted") }), { role = "periscope.desc", key = "desc", title = desc }))
	end
	return with(ui.col(kids), { role = role, key = "header" })
end

-- A transcript view with a header that stays put. `main` is virtualized (rows scrolled out of
-- sight are unmounted, so `position: sticky` cannot hold), hence the header is drawn in the
-- `layer` region, over the pane, and `main` starts with an invisible copy of it that reserves
-- the same height (see periscope.css).
local function framed(v: Viewer, bar: () -> { Node }, desc: string?, dock: Node): BlockView
	return {
		main = transcript.main(v, { header_block(bar, desc, "periscope.spacer") }),
		layer = with(ui.col({ header_block(bar, desc, "periscope.header") }), { role = "periscope.layer" }),
		dock = dock,
	}
end

-- Header of a drill-down transcript: back button first (far left), then name, status, and the
-- agent's requests, cost and running time, then the output-mode buttons.
local function transcript_view(state: ListState, v: Viewer): BlockView
	local a = state.viewing and state.agents[state.viewing]
	local function bar(): { Node }
		local nodes: { Node } = {
			with(ui.badge("← Back to agents", "accent"), { actions = { click = "back" }, key = "back", role = "periscope.filter", mark = "on" }),
			ui.text({ ui.span(v.label, "strong") }),
		}
		if a then
			local status = shown(state, a)
			table.insert(nodes, ui.badge(status, if status == "running" then "accent" else "neutral"))
			local facts: { string } = { a.requests .. " req", string.format("$%.2f", a.cost) }
			if a.started ~= nil then
				local to = if status == "running" then wall(state) else (a.last or wall(state))
				table.insert(facts, util.duration(math.max(0, to - a.started)))
			end
			table.insert(nodes, ui.text({ ui.span(table.concat(facts, " · "), "dim") }))
		end
		for _, b in transcript.output_buttons(v) do
			table.insert(nodes, b)
		end
		return nodes
	end
	return framed(v, bar, if a then a.task else nil, transcript.hints(v, "esc back · ←/→ agent"))
end

-- Facts about an agent for a header: status badge, then "N req · $cost · running time".
local function agent_facts(state: ListState, a: Agent): { Node }
	local status = shown(state, a)
	local facts: { string } = { a.requests .. " req", string.format("$%.2f", a.cost) }
	if a.started ~= nil then
		local to = if status == "running" then wall(state) else (a.last or wall(state))
		table.insert(facts, util.duration(math.max(0, to - a.started)))
	end
	return {
		ui.badge(status, if status == "running" then "accent" else "neutral"),
		ui.text({ ui.span(table.concat(facts, " · "), "dim") }),
	}
end

-- The split view: a picker of at most three visible rows (it scrolls) over one transcript, all in
-- this block. Picker and header live in the `layer` region so they stay put while `main` scrolls;
-- `main` starts with an invisible copy that reserves their height (periscope.css).
local function split_view(state: ListState): BlockView
	local n = counts(state)
	local v = state.viewer
	local a = if state.viewing ~= nil then state.agents[state.viewing] else nil
	local function picker(limit: number?): Node
		local head: { Node } = { ui.text({ ui.span("Periscope", "strong") }) }
		for _, b in filter_badges(state, n) do
			table.insert(head, b)
		end
		table.insert(head, sessions_badge(state))
		table.insert(head, layout_badge("List view", "list"))
		local rows: { Node } = {}
		for _, ag in visible(state) do
			if limit ~= nil and #rows >= limit then
				break
			end
			table.insert(rows, agent_node(state, ag))
		end
		if #rows == 0 then
			local text = if n.all == 0 then "No subagents in this session yet." else "No " .. string.lower(state.filter) .. " subagents."
			table.insert(rows, ui.text({ ui.span(text, "muted") }))
		end
		return with(ui.col({ ui.row(head), with(ui.col(rows), { key = "rows", role = "periscope.rows" }) }), { key = "picker", role = "periscope.panel" })
	end
	local function bar(): { Node }
		if v == nil then
			return { ui.text({ ui.span("Click a subagent to show its transcript here", "muted") }) }
		end
		local nodes: { Node } = { ui.text({ ui.span(v.label, "strong") }) }
		if a then
			for _, f in agent_facts(state, a) do
				table.insert(nodes, f)
			end
		end
		for _, b in transcript.output_buttons(v) do
			table.insert(nodes, b)
		end
		return nodes
	end
	local function divider(): Node
		return with(ui.col({ ui.text({ ui.span(" ") }) }), { role = "periscope.divider", key = "divider" })
	end
	local desc = if a then a.task else nil
	local spacer = with(ui.col({ picker(3), divider(), header_block(bar, desc, nil) }), { role = "periscope.spacer", key = "spacer" })
	local main = with(if v ~= nil then transcript.main(v, { spacer }) else ui.col({ spacer }), { role = "periscope.split" })
	local layer = with(
		ui.col({ picker(nil), divider(), header_block(bar, desc, "periscope.header") }),
		{ role = "periscope.layer" }
	)
	local hint = "←→ pick agent · ↑↓ scroll · c/e output · space fold · g/G top/end · f filter · o open below · s/S session · l list view"
	return { main = main, layer = layer, dock = ui.row({ ui.text({ ui.span(hint, "muted") }) }) }
end

local function split_key(state: ListState, key: Key, cx: BlockCx): boolean
	local name = key.name
	local plain = not (key.ctrl or key.alt or key.meta)
	if plain and (name == "escape" or name == "v") then
		set_layout(state, "list", cx)
	elseif plain and not key.shift and (name == "left" or name == "right") then
		step_agent(state, if name == "right" then 1 else -1, cx)
	elseif plain and name == "f" then
		set_filter(state, next_filter(state), cx)
	elseif (plain and name == "o") or (name == "enter" and key.meta) then
		if state.sel == nil then
			return false
		end
		open_below(state, state.sel, cx)
	else
		local v = state.viewer
		return if v ~= nil then transcript.key(v, key, cx) else false
	end
	return true
end

local list: BlockDef<ListState> = {
	init = function(cx, args, saved)
		local cwd = args[1] or cx.cwd
		local want = if args[2] ~= nil then agents.title_key(args[2]) else nil
		local state: ListState = {
			cwd = cwd,
			bucket = if cwd ~= nil then agents.bucket(cwd) else nil,
			sessions = {},
			pinned = if saved ~= nil then saved.pinned else nil,
			want = if want ~= nil and want ~= "" then want else nil,
			session = nil,
			agents = {},
			sizes = {},
			now = 0,
			mono = tern.now(),
			ticks = 0,
			busy = false,
			stopped = false,
			loaded = false,
			error = nil,
			sel = nil,
			filter = if saved ~= nil and valid_filter(saved.filter) then saved.filter else "all",
			layout = if saved ~= nil and saved.layout == "list" then "list" else "split",
			viewing = nil,
			viewer = nil,
			viewers = {},
			restore = if saved ~= nil then saved.viewing else nil,
			skip_empty = saved ~= nil and saved.skip_empty == true,
			picking = false,
		}
		local function tick()
			if state.stopped or not running(cx.pane) then
				return
			end
			local viewer = state.viewer
			if viewer ~= nil and transcript.due(viewer) then
				transcript.poll(viewer, false, function(changed)
					if changed then
						cx:render()
						transcript.follow_soon(viewer, cx)
					end
				end)
			end
			local function later()
				tern.timer(TICK_MS, tick)
			end
			if state.ticks % REFRESH_EVERY == 0 and not state.busy then
				state.busy = true
				scan(state, cx, function()
					state.busy = false
					state.loaded = true
					if state.viewer == nil or state.layout == "split" then
						if state.layout ~= "split" or state.sel == nil then
							ensure_sel(state)
						end
						if state.layout == "split" and state.viewer == nil and state.sel ~= nil then
							open_split(state, state.sel, cx)
						end
					end
					if running(cx.pane) then
						cx:render()
					end
					later()
				end)
			else
				later()
			end
			state.ticks += 1
		end
		tick()
		return state
	end,

	title = function(state)
		return title_of(state)
	end,

	view = function(state, _cx)
		if state.layout == "split" then
			return with_popup(state, split_view(state))
		end
		if state.viewer ~= nil then
			return with_popup(state, transcript_view(state, state.viewer))
		end
		return with_popup(state, list_view(state))
	end,

	key = function(state, key, cx)
		if state.picking and key.name == "escape" then
			state.picking = false
			return true
		end
		if not (key.ctrl or key.alt or key.meta) and string.lower(key.name) == "s" then
			step_session(state, if key.shift or key.name == "S" or key.text == "S" then -1 else 1, cx)
			return true
		end
		if not (key.ctrl or key.alt or key.meta) and key.name == "l" then
			set_layout(state, if state.layout == "split" then "list" else "split", cx)
			return true
		end
		if state.layout == "split" then
			return split_key(state, key, cx)
		end
		local v = state.viewer
		if v ~= nil then
			if key.name == "escape" then
				close_view(state, cx)
				return true
			elseif (key.name == "left" or key.name == "right") and not (key.ctrl or key.alt or key.meta or key.shift) then
				step_agent(state, if key.name == "right" then 1 else -1, cx)
				return true
			end
			return transcript.key(v, key, cx)
		end
		local order = visible(state)
		local at = 0
		for i, a in order do
			if a.file == state.sel then
				at = i
			end
		end
		if key.name == "j" or key.name == "down" then
			local nxt = order[math.min(at + 1, #order)]
			state.sel = if nxt ~= nil then nxt.file else nil
			reveal(state, cx, false)
		elseif key.name == "k" or key.name == "up" then
			local prev = order[math.max(at - 1, 1)]
			state.sel = if prev ~= nil then prev.file else nil
			reveal(state, cx, false)
		elseif key.name == "f" then
			set_filter(state, next_filter(state), cx)
		elseif key.name == "v" then
			set_layout(state, "split", cx)
		elseif key.name == "enter" or key.name == "space" or key.name == "o" then
			if state.sel == nil then
				return false
			end
			if key.meta or key.name == "o" then
				open_below(state, state.sel, cx)
			else
				open_here(state, state.sel, cx)
			end
		elseif key.name == "r" then
			state.sizes = {}
			scan(state, cx, function()
				cx:render()
			end)
			return false
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "open" and type(ev.value) == "string" then
			state.sel = ev.value
			if state.layout == "split" then
				open_split(state, ev.value, cx)
				return
			end
			-- click opens in this block; ⌘/ctrl-click opens a block below
			if has(ev.mods, "meta") or has(ev.mods, "ctrl") then
				open_below(state, ev.value, cx)
			else
				open_here(state, ev.value, cx)
			end
		elseif ev.act == "filter" and valid_filter(ev.value) then
			set_filter(state, ev.value, cx)
		elseif ev.act == "layout" and type(ev.value) == "string" then
			set_layout(state, ev.value, cx)
		elseif ev.act == "sessions" and type(ev.value) == "string" then
			if ev.value == "open" then
				state.picking = not state.picking
			elseif ev.value == "close" then
				state.picking = false
			elseif ev.value == "skip_empty" then
				state.skip_empty = not state.skip_empty
				relist(state, cx)
			end
		elseif ev.act == "session" and type(ev.value) == "string" then
			state.picking = false
			for _, s in state.sessions do
				if s.id == ev.value then
					switch_session(state, s, cx)
				end
			end
		elseif ev.act == "back" then
			close_view(state, cx)
		elseif ev.act == "pick" and state.viewer ~= nil and type(ev.value) == "string" then
			transcript.pick(state.viewer, ev.value)
		elseif ev.act == "outputs" and state.viewer ~= nil and type(ev.value) == "string" then
			transcript.set_outputs(state.viewer, ev.value, cx)
		end
	end,

	save = function(state)
		return { pinned = state.pinned, viewing = state.viewing, filter = state.filter, layout = state.layout, skip_empty = state.skip_empty }
	end,
}

tern.block.define("list", list)

------------------------------------------------------------------------------------------
-- periscope.transcript
------------------------------------------------------------------------------------------

type TranscriptState = { viewer: Viewer, stopped: boolean }

local transcript_block: BlockDef<TranscriptState> = {
	init = function(cx, args, saved)
		local path = args[1] or (if saved ~= nil then saved.path else nil)
		local label = args[2] or (if saved ~= nil then saved.label else nil)
		local viewer = transcript.new(path or "", label or util.strip_suffix(util.basename(path or ""), ".jsonl"))
		local state: TranscriptState = { viewer = viewer, stopped = path == nil }
		if path == nil then
			viewer.error = "No transcript path given"
			viewer.loaded = true
			return state
		end
		local function tick()
			if state.stopped or not running(cx.pane) then
				return
			end
			local function later()
				tern.timer(TICK_MS, tick)
			end
			if transcript.due(viewer) then
				transcript.poll(viewer, false, function(changed)
					if changed and running(cx.pane) then
						cx:render()
						transcript.follow_soon(viewer, cx)
					end
					later()
				end)
			else
				later()
			end
		end
		transcript.poll(viewer, true, function()
			cx:render()
			transcript.follow_soon(viewer, cx)
			tern.timer(TICK_MS, tick)
		end)
		return state
	end,

	title = function(state)
		return state.viewer.label
	end,

	view = function(state, _cx)
		local v = state.viewer
		return framed(v, function()
			local nodes: { Node } = { ui.text({ ui.span(v.label, "strong"), ui.span("  " .. v.path, "dim") }) }
			for _, b in transcript.output_buttons(v) do
				table.insert(nodes, b)
			end
			return nodes
		end, nil, transcript.hints(v, nil))
	end,

	key = function(state, key, cx)
		return transcript.key(state.viewer, key, cx)
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "pick" and type(ev.value) == "string" then
			transcript.pick(state.viewer, ev.value)
		elseif ev.act == "outputs" and type(ev.value) == "string" then
			transcript.set_outputs(state.viewer, ev.value, cx)
		end
	end,

	save = function(state)
		return { path = state.viewer.path, label = state.viewer.label }
	end,
}

tern.block.define("transcript", transcript_block)
