-- lib/agents.luau: status from transcript digests (classify, shown/STALE_MS), where omp keeps
-- sessions (sessions_root, bucket) and parsing of scan.sh's sessions/sizes/init/agent output.

local check = require("./check")
local stub = require("./tern_stub")
local agents = require("../lib/agents")

local function d(kind: string, sub: string, ts: number?, extra: string?)
	return { kind = kind, sub = sub, ts = ts, extra = extra or "" }
end

local function classify(...)
	return agents.classify({ ... })
end

-- classify --------------------------------------------------------------------------------

check.test("classify: tool_execution_start is running with tool and intent", function()
	check.eq(classify(d("c", "tool_execution_start", 100, 'bash|{"command":"ls","i":"List files"}')), {
		status = "running",
		tool = "bash",
		intent = "List files",
		tool_started = 100,
		last = 100,
	})
end)

check.test("classify: tool result and user message are running", function()
	check.eq(classify(d("m", "toolResult", 7)), { status = "running", last = 7 })
	check.eq(classify(d("m", "user", 8)), { status = "running", last = 8 })
end)

check.test("classify: assistant turn endings", function()
	check.eq(classify(d("m", "assistant", 5, "toolUse|read,bash")), { status = "running", tool = "read", last = 5 })
	check.eq(classify(d("m", "assistant", 5, "stop|")), { status = "idle", last = 5 })
	check.eq(classify(d("m", "assistant", 5, "error|")), { status = "failed", last = 5 })
	check.eq(classify(d("m", "assistant", 5, "aborted|")), { status = "aborted", last = 5 })
end)

check.test("classify: session_exit", function()
	check.eq(classify(d("c", "session_exit", 9, "normal")), { status = "parked", last = 9 })
	check.eq(classify(d("c", "session_exit", 9, "signal")), { status = "aborted", last = 9 })
end)

check.test("classify: the newest significant entry wins", function()
	check.eq(classify(d("m", "assistant", 1, "toolUse|bash"), d("m", "assistant", 2, "stop|")).status, "idle")
	check.eq(classify(d("m", "assistant", 1, "stop|"), d("m", "user", 2)).status, "running")
	check.eq(classify(d("c", "session_exit", 1, "normal"), d("m", "assistant", 2, "error|")).status, "failed")
	check.eq(classify(d("m", "toolResult", 1), d("c", "session_exit", 2, "signal")).status, "aborted")
end)

check.test("classify: unknown entries are skipped", function()
	check.eq(classify(d("m", "assistant", 1, "stop|"), d("m", "custom", 2), d("c", "other", 3)).status, "idle")
end)

check.test("classify: no significant entry is pending", function()
	check.eq(classify(), { status = "pending" })
	check.eq(classify(d("m", "custom", 1), d("c", "other", 4)), { status = "pending", last = 4 })
end)

local function intent(extra: string): string?
	return classify(d("c", "tool_execution_start", 1, extra)).intent
end

check.test("classify intent: wait, preferred keys, fallbacks", function()
	check.eq(intent('wait|{"ids":["bg_1"]}'), "Waiting for background jobs")
	check.eq(intent('bash|{"command":"make test","i":"Running tests"}'), "Running tests")
	check.eq(intent('bash|{"i":"","command":"make test"}'), "make test")
	check.eq(intent('read|{"path":"/home/u/proj/a.txt"}'), "/home/u/proj/a.txt")
	check.eq(intent('grep|{"pattern":"TODO"}'), "TODO")
	check.eq(intent('web_search|{"query":"luau utf8"}'), "luau utf8")
	check.eq(intent('noop|{"n":1}'), nil)
end)

check.test("classify intent: args cut at 400 chars by agent.awk", function()
	local args = string.sub('{"command":"echo ' .. string.rep("x", 500) .. '"}', 1, 400)
	check.eq(intent("bash|" .. args), "echo " .. string.rep("x", 114) .. "…")
	check.eq(intent('bash|{"command":"echo hi'), "echo hi")
end)

check.test("classify intent: escapes undone, one line", function()
	check.eq(intent([[bash|{"i":"Say \"hi\"\nthen\\leave"}]]), 'Say "hi" then\\leave')
end)

check.test("classify intent: long intent cut to 120 chars", function()
	check.eq(intent('bash|{"i":"' .. string.rep("a", 120) .. '"}'), string.rep("a", 120))
	check.eq(intent('bash|{"i":"' .. string.rep("a", 121) .. '"}'), string.rep("a", 119) .. "…")
end)

-- shown / STALE_MS ------------------------------------------------------------------------

check.test("STALE_MS is the documented 45 minutes", function()
	check.eq(agents.STALE_MS, 45 * 60 * 1000)
end)

check.test("shown: running goes idle only after STALE_MS of silence", function()
	local a: any = { status = "running", last = 1000 }
	check.eq(agents.shown(a, 1000 + agents.STALE_MS), "running")
	check.eq(agents.shown(a, 1000 + agents.STALE_MS + 1), "idle")
	check.eq(agents.shown({ status = "running" } :: any, 10 * agents.STALE_MS), "running")
end)

check.test("shown: other statuses ignore age", function()
	for _, status in { "failed", "parked", "idle", "aborted", "pending" } do
		check.eq(agents.shown({ status = status, last = 0 } :: any, 10 * agents.STALE_MS), status)
	end
end)

-- sessions_root / bucket ------------------------------------------------------------------

check.test("sessions_root: env precedence", function()
	stub.env = {
		HOME = "/home/u",
		PI_CONFIG_DIR = ".cfg",
		PI_CODING_AGENT_DIR = "/agent",
		PI_CODING_AGENT_SESSION_DIR = "/sess",
	}
	check.eq(agents.sessions_root(), "/sess")
	stub.env.PI_CODING_AGENT_SESSION_DIR = ""
	check.eq(agents.sessions_root(), "/agent/sessions")
	stub.env.PI_CODING_AGENT_DIR = ""
	check.eq(agents.sessions_root(), "/home/u/.cfg/agent/sessions")
	stub.env.PI_CONFIG_DIR = nil
	check.eq(agents.sessions_root(), "/home/u/.omp/agent/sessions")
	stub.env.HOME = nil
	check.eq(agents.sessions_root(), nil)
end)

check.test("sessions_root: overrides need no HOME", function()
	stub.env = { PI_CODING_AGENT_DIR = "/agent" }
	check.eq(agents.sessions_root(), "/agent/sessions")
end)

check.test("bucket: under home, outside home, trailing slashes", function()
	stub.env = { HOME = "/home/u" }
	local root = "/home/u/.omp/agent/sessions"
	check.eq(agents.bucket("/home/u/proj/sub"), root .. "/-proj-sub")
	check.eq(agents.bucket("/home/u/proj//"), root .. "/-proj")
	check.eq(agents.bucket("/opt/x/y"), root .. "/--opt-x-y--")
	check.eq(agents.bucket("/opt/x/"), root .. "/--opt-x--")
	check.eq(agents.bucket("/home/user2/x"), root .. "/--home-user2-x--")
end)

check.test("bucket: no sessions root", function()
	check.eq(agents.bucket("/home/u/proj"), nil)
end)

-- parse_sessions / parse_sizes ------------------------------------------------------------

check.test("parse_sessions: now, rows, malformed lines skipped, order kept", function()
	local out = table.concat({
		"now 1767261601",
		'2026-01-01T10-00-00-000Z_abc_1.jsonl\t3\t1\t{"type":"session","title":"Fix\u{E0A0} the \\"bug\\""}',
		"garbage",
		"notes.txt\t1\t0\t{}",
		"bad.jsonl\tx\t0\t{}",
		'plain.jsonl\t0\t0\t{"type":"session"}',
		"",
	}, "\n")
	local sessions, now = agents.parse_sessions(out, "/s/b")
	check.eq(now, 1767261601000)
	check.eq(sessions, {
		{
			file = "2026-01-01T10-00-00-000Z_abc_1.jsonl",
			id = "abc_1",
			dir = "/s/b/2026-01-01T10-00-00-000Z_abc_1",
			title = 'Fix the "bug"',
			subagents = 3,
			running = 1,
		},
		{ file = "plain.jsonl", id = "plain", dir = "/s/b/plain", title = "", subagents = 0, running = 0 },
	})
end)

check.test("parse_sessions: no now line", function()
	local sessions, now = agents.parse_sessions("", "/s/b")
	check.eq(sessions, {})
	check.eq(now, nil)
end)

check.test("parse_sizes", function()
	local sizes, now = agents.parse_sizes("now 5\n120\tA.jsonl\n7\tB C.jsonl\nbad line\nx\tC.jsonl\n")
	check.eq(now, 5000)
	check.eq(sizes, { ["A.jsonl"] = 120, ["B C.jsonl"] = 7 })
end)

-- parse_inits -----------------------------------------------------------------------------

check.test("parse_inits: decodes session_init and cleans the task blurb", function()
	local out = table.concat({
		"@@\tA.jsonl",
		'{"type":"session_init","agent":"task","resolvedModel":"anthropic/m","task":"Complete assignment thoroughly:\\n\\n# Target\\nFix the parser\\n\\n## Change\\nDo it"}',
		"@@\tB.jsonl",
		"@@\tC.jsonl",
		'{"type":"session_init","task":"trunc',
		"@@\tD.jsonl",
		'{"type":"session_init","agent":"explore","task":"' .. string.rep("w ", 150) .. '"}',
	}, "\n")
	local inits = agents.parse_inits(out)
	check.eq(inits["A.jsonl"], { agent_kind = "task", model = "anthropic/m", task = "Fix the parser Change Do it" })
	check.eq(inits["B.jsonl"], {})
	check.eq(inits["C.jsonl"], {})
	check.eq(inits["D.jsonl"].agent_kind, "explore")
	check.eq(inits["D.jsonl"].task, string.sub(string.rep("w ", 100), 1, 199) .. "…")
end)

-- parse_digests ---------------------------------------------------------------------------

-- tests/fixtures/awk/basic.expected verbatim (the luau CLI has no io to read it).
local AWK_BASIC = table.concat({
	"stats\t1\t2\t0.532300\t2345\t2026-01-01T10:00:01.000Z",
	"e\tm\tuser\t2026-01-01T10:00:01.000Z\t",
	"e\tm\tassistant\t2026-01-01T10:00:05.000Z\ttoolUse|bash",
	'e\tc\ttool_execution_start\t2026-01-01T10:00:06.000Z\tbash|{"command":"ls\\tfoo","i":"List"}}',
	"e\tm\ttoolResult\t2026-01-01T10:00:07.000Z\t",
	"e\tm\tassistant\t2026-01-01T10:00:09.000Z\tstop|",
	"e\tc\tsession_exit\t2026-01-01T10:00:10.000Z\tnormal",
	"",
}, "\n")

check.test("parse_digests: agent.awk output", function()
	local result = agents.parse_digests("@@\tWorker.jsonl\n" .. AWK_BASIC)
	local w = result["Worker.jsonl"]
	check.eq(w.tools, 1)
	check.eq(w.requests, 2)
	check.eq(w.cost, 0.5323)
	check.eq(w.tokens, 2345)
	check.eq(w.started, 1767261601000)
	check.eq(#w.digests, 6)
	check.eq(w.digests[1], { kind = "m", sub = "user", ts = 1767261601000, extra = "" })
	check.eq(w.digests[2], { kind = "m", sub = "assistant", ts = 1767261605000, extra = "toolUse|bash" })
	check.eq(agents.classify(w.digests), { status = "parked", last = 1767261610000 })
	table.remove(w.digests)
	check.eq(agents.classify(w.digests), { status = "idle", last = 1767261609000 })
	table.remove(w.digests)
	table.remove(w.digests)
	check.eq(agents.classify(w.digests), {
		status = "running",
		tool = "bash",
		intent = "List",
		tool_started = 1767261606000,
		last = 1767261606000,
	})
end)

check.test("parse_digests: missing fields default, short records skipped", function()
	local out = table.concat({
		"stats\t0\t0\t0\t0\t",
		"e\tm\tuser\t2026-01-01T10:00:01Z",
		"e\tm\tuser",
		"@@\tB.jsonl",
		"e\tm\tassistant\tnot-a-date\tstop|",
		"@@\tC.jsonl",
		"stats\t3",
	}, "\n")
	local result = agents.parse_digests("@@\tA.jsonl\n" .. out)
	check.eq(result["A.jsonl"], {
		tools = 0,
		requests = 0,
		cost = 0,
		tokens = 0,
		digests = { { kind = "m", sub = "user", ts = 1767261601000, extra = "" } },
	})
	check.eq(result["B.jsonl"], {
		tools = 0,
		requests = 0,
		cost = 0,
		tokens = 0,
		digests = { { kind = "m", sub = "assistant", extra = "stop|" } },
	})
	check.eq(result["C.jsonl"], { tools = 3, requests = 0, cost = 0, tokens = 0, digests = {} })
end)

check.test("parse_digests: lines before the first frame are ignored", function()
	check.eq(agents.parse_digests("stats\t1\t1\t1\t1\t\ne\tm\tuser\t2026-01-01T10:00:01Z\t\n"), {})
end)

-- title_key / json_string -----------------------------------------------------------------

check.test("title_key: drops private-use glyphs and surrounding blanks", function()
	check.eq(agents.title_key("\u{F0001}  Fix the bug \u{E000} "), "Fix the bug")
	check.eq(agents.title_key("\u{E0A0}Plain"), "Plain")
	check.eq(agents.title_key("  "), "")
end)

check.test("json_string", function()
	check.eq(agents.json_string('{"a":"x","title":"Say \\"hi\\"\\n"}', "title"), 'Say "hi"\n')
	check.eq(agents.json_string('{"title":"cut off \\"mid', "title"), 'cut off "mid')
	check.eq(agents.json_string('{"name":"x"}', "title"), nil)
	check.eq(agents.json_string('{"title":""}', "title"), "")
end)

check.done()
