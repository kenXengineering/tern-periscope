-- lib/transcript.luau: folding omp JSONL records into entries, loading the tail through
-- scan.sh, cursor/fold/output-mode keys, and the nodes the transcript view draws.

local check = require("./check")
local stub = require("./tern_stub")
local M = require("../lib/transcript")

local test, eq = check.test, check.eq

-- Fixtures ------------------------------------------------------------------------------

-- Minimal JSON encoder for fixture lines; "type" goes first because parse matches the line head.
local function enc(v: any): string
	local t = type(v)
	if t == "string" then
		local s = string.gsub(v, '[%c"\\]', function(c)
			local named = ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" })[c]
			return named or string.format("\\u%04x", string.byte(c))
		end)
		return '"' .. s .. '"'
	elseif t ~= "table" then
		return tostring(v)
	elseif #v > 0 then
		local parts = {}
		for _, x in v do
			table.insert(parts, enc(x))
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		if a == "type" or b == "type" then
			return a == "type"
		end
		return a < b
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, enc(k) .. ":" .. enc(v[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- 2026-01-01T10:00:00.000Z plus `ms` (under a minute)
local function ts(ms: number): string
	return string.format("2026-01-01T10:00:%02d.%03dZ", ms // 1000, ms % 1000)
end

local function user(id: string, content: any, ms: number?): any
	return { type = "message", id = id, timestamp = ts(ms or 0), message = { role = "user", content = content } }
end

local function asst(id: string, blocks: { any }, ms: number?, extra: { [string]: any }?): any
	local msg: { [string]: any } = { role = "assistant", content = blocks }
	for k, x in extra or {} do
		msg[k] = x
	end
	return { type = "message", id = id, timestamp = ts(ms or 0), message = msg }
end

local function text(s: string): any
	return { type = "text", text = s }
end

local function call(id: string, name: string, args: { [string]: any }?): any
	return { type = "toolCall", id = id, name = name, arguments = args or {} }
end

local function result(id: string, call_id: string, name: string?, content: any, is_error: boolean?, ms: number?): any
	return {
		type = "message",
		id = id,
		timestamp = ts(ms or 0),
		message = { role = "toolResult", toolCallId = call_id, toolName = name, isError = is_error == true, content = content },
	}
end

local function lines(n: number, prefix: string?): string
	local out = {}
	for i = 1, n do
		out[i] = (prefix or "l") .. i
	end
	return table.concat(out, "\n")
end

local function pluck(entries: { any }, field: string): { any }
	local out = {}
	for i, e in entries do
		out[i] = if e[field] == nil then false else e[field]
	end
	return out
end

local function find(node: any, kind: string, out: { any }?): { any }
	local found = out or {}
	if type(node) == "table" then
		if node.k == kind then
			table.insert(found, node)
		end
		for _, c in node.c or {} do
			find(c, kind, found)
		end
	end
	return found
end

local function loaded(records: { any }, mode: string?): any
	local v = M.new("/home/u/.omp/s.jsonl", "s")
	v.loaded = true
	v.outputs = mode or "preview"
	v.entries = M.build(records)
	return v
end

-- The tool node drawn for one call + result.
local function tool_view(mode: string, name: string, args: { [string]: any }, out: string): any
	local v = loaded({ asst("a1", { call("c1", name, args) }, 0), result("r1", "c1", name, { text(out) }, false, 1000) }, mode)
	return find(M.main(v), "tool")[1]
end

local function fake_cx(): any
	local cx = { frames = {}, renders = 0 }
	function cx.frame(self: any, f: any)
		table.insert(self.frames, f)
	end
	function cx.render(self: any)
		self.renders += 1
	end
	return cx
end

local function key(name: string, mods: { [string]: any }?): any
	local k: { [string]: any } = { name = name, text = name }
	for m, x in mods or {} do
		k[m] = x
	end
	return k
end

-- n assistant messages; entry i has key "am<i>_1"
local function viewer(n: number): any
	local records = {}
	for i = 1, n do
		records[i] = asst("m" .. i, { text("msg " .. i) })
	end
	local v = loaded(records)
	v.cursor = n
	return v
end

-- build / parse ---------------------------------------------------------------------------

test("entry kinds and texts", function()
	local entries = M.build({
		user("u1", "fix the bug"),
		user("u2", { text("part one"), { type = "image", data = "x" }, text("part two") }),
		asst("a1", { { type = "thinking", thinking = "hmm" }, text("done"), call("c1", "bash", { command = "ls" }) }),
		result("r1", "c1", "bash", "ok"),
	})
	eq(pluck(entries, "kind"), { "user", "user", "thinking", "assistant", "tool" })
	eq(pluck(entries, "text"), { "fix the bug", "part one\npart two", "hmm", "done", false })
	eq(entries[5].name, "bash")
	eq(entries[5].args, { command = "ls" })
end)

test("turn_start marks the first entry after each user message and assistant request", function()
	local entries = M.build({
		user("u1", "go"),
		asst("a1", { { type = "thinking", thinking = "t" }, text("x"), call("c1", "bash") }),
		result("r1", "c1", "bash", "out"),
		asst("a2", { text("y") }),
		user("u2", ""), -- empty prompt draws nothing; the next entry opens the turn
		asst("a3", { text("z") }),
	})
	eq(pluck(entries, "kind"), { "user", "thinking", "assistant", "tool", "assistant", "assistant" })
	eq(pluck(entries, "turn_start"), { true, true, false, false, true, true })
end)

test("tool result pairs with its call", function()
	local entries = M.build({
		asst("a1", { call("c1", "bash"), call("c2", "read") }, 1000),
		result("r1", "c1", "bash", { text("line a"), text("line b") }, false, 3500),
		result("r2", "c2", "read", "no such file", true, 1200),
	})
	eq(#entries, 2)
	eq(entries[1].result, "line a\nline b")
	eq(entries[1].status, "done")
	eq(entries[1].took, 2500)
	eq(entries[2].result, "no such file")
	eq(entries[2].status, "error")
	eq(entries[2].took, 200)
end)

test("a result whose call fell off the tail is its own tool entry", function()
	local entries = M.build({
		result("r1", "gone", "grep", "hit", false),
		result("r2", "gone2", nil, "bad", true),
	})
	eq(entries, {
		{ key = "rr1", kind = "tool", name = "grep", args = {}, result = "hit", status = "done", foldable = true },
		{ key = "rr2", kind = "tool", name = "result", args = {}, result = "bad", status = "error", foldable = true },
	})
end)

test("a call without result is running only when last", function()
	eq(M.build({ asst("a1", { call("c1", "bash") }) })[1].status, "running")
	local entries = M.build({ asst("a1", { call("c1", "bash"), text("meanwhile") }) })
	eq(entries[1].status, "cancelled")
end)

test("stopReason error/aborted adds a note and cancels the open call", function()
	local entries = M.build({
		asst("a1", { call("c1", "bash") }, 0, { stopReason = "aborted" }),
		asst("a2", { text("partial") }, 0, { stopReason = "error", errorMessage = "rate limited" }),
		asst("a3", { text("fine") }, 0, { stopReason = "stop" }),
	})
	eq(pluck(entries, "kind"), { "tool", "note", "assistant", "note", "assistant" })
	eq(entries[1].status, "cancelled")
	eq(entries[2].text, "Turn aborted: aborted")
	eq(entries[4].text, "Turn error: rate limited")
end)

test("session_exit note shows its kind, normal by default", function()
	local entries = M.build({
		{ type = "custom", customType = "session_exit", id = "e1", data = { kind = "crash" } },
		{ type = "custom", customType = "session_exit", id = "e2" },
		{ type = "custom", customType = "other", id = "e3" },
	})
	eq(pluck(entries, "text"), { "Session exited (crash)", "Session exited (normal)" })
	eq(pluck(entries, "kind"), { "note", "note" })
end)

test("assistant text folds only above 12 lines", function()
	local entries = M.build({ asst("a1", { text(lines(12)), text(lines(13)) }) })
	eq(pluck(entries, "foldable"), { false, true })
	local v = loaded({ asst("a1", { text(lines(12)), text(lines(13)) }) })
	local list = find(M.main(v), "col")[2].c
	eq({ list[1].k, list[2].k }, { "md", "section" })
end)

test("keys are sanitized and do not depend on position", function()
	local a = user("msg/1:x", "one")
	local b = asst("m 2.y", { text("two"), call("call.9 z!", "bash") })
	local both = M.build({ a, b })
	eq(pluck(both, "key"), { "umsg_1_x", "am_2_y_1", "tcall_9_z_" })
	eq(pluck(M.build({ b }), "key"), { "am_2_y_1", "tcall_9_z_" })
end)

test("parse skips other records and broken lines", function()
	local out = table.concat({
		'{"type":"session_init","cwd":"/home/u/proj"}',
		enc(user("u1", "first")),
		'{"type":"message","id":"u2","message":{"role":"user","content":"trunc',
		'{"type":"message",oops}',
		"",
		"not json",
		enc({ type = "custom", customType = "session_exit", id = "e1", data = { kind = "signal" } }),
		enc(user("u3", "last")),
	}, "\n")
	local entries = M.parse(out)
	eq(pluck(entries, "text"), { "first", "Session exited (signal)", "last" })
end)

-- poll ------------------------------------------------------------------------------------

-- scan.sh fake: `size` prints `size`, `tail` prints `tail` (or fails with `fail` stderr).
local function serve(size: string, tail: string, fail: { [string]: string }?)
	stub.run = function(argv)
		local sub = argv[3]
		if fail and fail[sub] then
			return { status = 1, stdout = "", stderr = fail[sub] }
		end
		return { status = 0, stdout = if sub == "size" then size .. "\n" else tail, stderr = "" }
	end
end

local function users(n: number): string
	local out = {}
	for i = 1, n do
		out[i] = enc(user("m" .. i, "p" .. i)) .. "\n"
	end
	return table.concat(out)
end

local function subcmds(): { string }
	local out = {}
	for i, argv in stub.calls do
		out[i] = table.concat(argv, " ", 3)
	end
	return out
end

test("first load fills entries and lands on the newest", function()
	serve("120", users(5))
	local v = M.new("/home/u/.omp/s.jsonl", "s")
	local got = {}
	M.poll(v, false, function(changed)
		table.insert(got, changed)
	end)
	eq(got, { true })
	eq(subcmds(), { "size /home/u/.omp/s.jsonl", "tail /home/u/.omp/s.jsonl 400" })
	eq({ v.loaded, v.size, #v.entries, v.cursor, v.more, v.busy }, { true, 120, 5, 5, false, false })
end)

test("only the newest 160 entries are kept", function()
	serve("1", users(160))
	local v = M.new("/x", "x")
	M.poll(v, false, function() end)
	eq({ #v.entries, v.entries[1].key, v.cursor }, { 160, "um1", 160 })

	stub.reset()
	serve("1", users(170))
	v = M.new("/x", "x")
	M.poll(v, false, function() end)
	eq({ #v.entries, v.entries[1].key, v.entries[160].key }, { 160, "um11", "um170" })
end)

test("more is set when the tail filled the requested lines", function()
	serve("1", string.rep("x\n", 399))
	local v = M.new("/x", "x")
	M.poll(v, false, function() end)
	eq(v.more, false)
	serve("2", string.rep("x\n", 400))
	M.poll(v, false, function() end)
	eq(v.more, true)
	local view = M.main(v)
	local notice = find(view, "text")[2]
	eq({ notice.p.key, notice.p.spans[1].t }, { "more", "Earlier history not shown. Press p to load more." })
end)

test("unchanged size skips the tail unless forced", function()
	serve("50", users(2))
	local v = M.new("/x", "x")
	M.poll(v, false, function() end)
	stub.calls = {}
	local got = {}
	M.poll(v, false, function(changed)
		table.insert(got, changed)
	end)
	eq(subcmds(), { "size /x" })
	M.poll(v, true, function(changed)
		table.insert(got, changed)
	end)
	eq(subcmds(), { "size /x", "size /x", "tail /x 400" })
	eq(got, { false, true })
end)

test("scan failure sets error and shows it; a later success clears it", function()
	serve("1", "", { size = "no such file" })
	local v = M.new("/x", "x")
	local got = {}
	M.poll(v, false, function(changed)
		table.insert(got, changed)
	end)
	eq({ got, v.error, v.loaded, v.busy }, { { true }, "no such file", false, false })
	local spans = find(M.main(v), "text")[1].p.spans
	eq({ spans[1].t, spans[2].t }, { "Cannot read transcript: ", "no such file" })

	serve("1", "", { tail = "tail broke" })
	M.poll(v, false, function() end)
	eq({ v.error, v.loaded }, { "tail broke", false })

	serve("1", users(1))
	M.poll(v, false, function() end)
	eq({ v.error, v.loaded }, { nil, true })
end)

test("a poll while one is in flight does nothing", function()
	local v = M.new("/x", "x")
	local inner = 0
	stub.run = function(argv)
		if argv[3] == "size" and #stub.calls == 1 then
			M.poll(v, true, function()
				inner += 1
			end)
		end
		return { status = 0, stdout = if argv[3] == "size" then "1" else users(1), stderr = "" }
	end
	M.poll(v, false, function() end)
	eq({ #stub.calls, inner }, { 2, 0 })
end)

test("p loads 400 more lines", function()
	serve("1", users(1))
	local v = M.new("/x", "x")
	M.poll(v, false, function() end)
	stub.calls = {}
	local cx = fake_cx()
	eq(M.key(v, key("p"), cx), false)
	eq(subcmds(), { "size /x", "tail /x 800" })
	eq(cx.renders, 1)
end)

-- keys --------------------------------------------------------------------------------------

test("j/k/up/down move and clamp", function()
	local v = viewer(3)
	local cx = fake_cx()
	v.cursor = 1
	eq(M.key(v, key("k"), cx), true)
	eq(v.cursor, 1)
	M.key(v, key("down"), cx)
	eq(v.cursor, 2)
	M.key(v, key("j"), cx)
	M.key(v, key("j"), cx)
	eq(v.cursor, 3)
	M.key(v, key("up"), cx)
	eq(v.cursor, 2)
	eq(cx.frames[#cx.frames], { { "reveal", "main.entries.am2_1", "nearest" } })
end)

test("page keys move 8 and clamp", function()
	local v = viewer(20)
	local cx = fake_cx()
	v.cursor = 1
	M.key(v, key("page_down"), cx)
	eq(v.cursor, 9)
	v.cursor = 15
	M.key(v, key("page_down"), cx)
	eq(v.cursor, 20)
	M.key(v, key("page_up"), cx)
	eq(v.cursor, 12)
	v.cursor = 5
	M.key(v, key("page_up"), cx)
	eq(v.cursor, 1)
end)

test("g/home go to the top; G/end to the newest with follow on", function()
	local v = viewer(5)
	local cx = fake_cx()
	v.cursor = 3
	M.key(v, key("g"), cx)
	eq(v.cursor, 1)
	M.key(v, { name = "g", text = "G", shift = true }, cx)
	eq({ v.cursor, v.follow }, { 5, true })
	eq(cx.frames[#cx.frames], { { "reveal", "main.entries.am5_1", "end" } })
	M.key(v, key("home"), cx)
	eq({ v.cursor, v.follow }, { 1, false })
	M.key(v, key("end"), cx)
	eq({ v.cursor, v.follow }, { 5, true })
end)

test("leaving the newest entry stops following; moving onto it resumes", function()
	local v = viewer(3)
	local cx = fake_cx()
	v.follow = true
	M.key(v, key("k"), cx)
	eq({ v.cursor, v.follow }, { 2, false })
	M.key(v, key("j"), cx)
	eq({ v.cursor, v.follow }, { 3, true })
end)

test("ctrl/alt/meta keys are ignored", function()
	local v = viewer(3)
	local cx = fake_cx()
	for _, mod in { "ctrl", "alt", "meta" } do
		eq(M.key(v, key("k", { [mod] = true }), cx), false, mod)
	end
	eq({ v.cursor, #cx.frames }, { 3, 0 })
end)

-- user (1), tool with output (2), note (3), long assistant reply (4)
local function mixed(): any
	return loaded({
		user("u1", "hi"),
		asst("a1", { call("c1", "bash", { command = "ls" }) }),
		result("r1", "c1", "bash", "a\nb"),
		asst("a2", {}, 0, { stopReason = "error", errorMessage = "boom" }),
		asst("a3", { text(lines(13)) }),
	})
end

test("space folds the cursor entry", function()
	local v = mixed()
	local cx = fake_cx()
	v.cursor = 2
	M.key(v, key("space"), cx)
	eq(v.expanded.tc1, true)
	M.key(v, key("space"), cx)
	eq(v.expanded.tc1, false)
	v.cursor = 3 -- the note is not foldable
	M.key(v, key("space"), cx)
	eq(v.expanded.xa2, nil)
	v.cursor = 4
	M.key(v, key("space"), cx)
	eq(v.expanded.aa3_1, true)
	v.cursor = 1
	M.key(v, key("space"), cx)
	eq(v.expanded.uu1, true)
end)

test("space on a tool flips relative to full output mode", function()
	local v = mixed()
	v.outputs = "full"
	v.cursor = 2
	M.key(v, key("space"), fake_cx())
	eq(v.expanded.tc1, false)
	eq(find(M.main(v), "tool")[1].p.collapsed, true)
end)

test("c/e switch output mode; pressing again returns to preview", function()
	local v = mixed()
	local cx = fake_cx()
	local seen = {}
	for _, k in { "c", "c", "e", "e", "e", "c" } do
		M.key(v, key(k), cx)
		table.insert(seen, v.outputs)
	end
	eq(seen, { "hidden", "preview", "full", "preview", "full", "hidden" })
end)

test("switching mode drops per-tool overrides only", function()
	local v = mixed()
	local cx = fake_cx()
	v.cursor = 2
	v.expanded = { tc1 = false, uu1 = true }
	M.key(v, key("e"), cx)
	eq(v.expanded, { uu1 = true })
	eq(find(M.main(v), "tool")[1].p.collapsed, false)
	stub.flush()
	eq(cx.frames, { { { "reveal", "main.entries.tc1", "nearest" } } })
end)

test("pick moves the cursor and toggles a tool with output", function()
	local v = mixed()
	v.cursor = 5
	v.follow = true
	M.pick(v, "tc1")
	eq({ v.cursor, v.follow, v.expanded.tc1 }, { 2, false, true })
	M.pick(v, "tc1")
	eq(v.expanded.tc1, false)
	M.pick(v, "uu1")
	eq({ v.cursor, v.expanded.uu1 }, { 1, nil })
	M.pick(v, "nope")
	eq(v.cursor, 1)

	local running = loaded({ asst("a1", { call("c9", "bash") }) })
	M.pick(running, "tc9")
	eq({ running.cursor, running.expanded.tc9 }, { 1, nil })
end)

-- rendering ---------------------------------------------------------------------------------

test("preview shows the first 3 output lines", function()
	local t = tool_view("preview", "bash", {}, lines(5))
	eq({ t.c[1].k, t.c[1].p.text, t.p.note, t.p.collapsed }, { "ansi", "l1\nl2\nl3", "2 more lines · click to expand", true })
	t = tool_view("preview", "bash", {}, lines(3))
	eq({ #t.c, t.c[1].p.text, t.p.note }, { 1, "l1\nl2\nl3", nil })
end)

test("hidden mode shows only a line count", function()
	local t = tool_view("hidden", "bash", {}, lines(5))
	eq({ #t.c, t.p.note, t.p.collapsed }, { 0, "5 lines · click to expand", true })
	t = tool_view("hidden", "bash", {}, "one")
	eq(t.p.note, "1 line · click to expand")
end)

test("full mode shows everything", function()
	local t = tool_view("full", "bash", {}, lines(5))
	eq({ t.c[1].p.text, t.p.note, t.p.collapsed }, { lines(5), "click to collapse", false })
	t = tool_view("full", "bash", {}, lines(3))
	eq({ t.c[1].p.text, t.p.note }, { lines(3), nil })
end)

test("long output is truncated at 120 lines or 6000 chars", function()
	eq(tool_view("full", "bash", {}, lines(120)).c[1].p.text, lines(120))
	eq(tool_view("full", "bash", {}, lines(121)).c[1].p.text, lines(120) .. "\n… output truncated")
	local wide = string.rep("a", 6000)
	eq(tool_view("full", "bash", {}, wide).c[1].p.text, wide)
	eq(tool_view("full", "bash", {}, wide .. "b").c[1].p.text, wide .. "\n… output truncated")
end)

test("result kinds: diff, json, code, ansi", function()
	local diff = "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n-a\n+b"
	local d = tool_view("full", "edit", { path = "x.go" }, diff).c[1]
	eq({ d.k, d.p.text, d.p.path }, { "diff", diff, "x.go" })
	eq(tool_view("full", "bash", {}, '  {"ok":true}\n').c[1], { k = "json_tree", p = { text = '{"ok":true}' }, c = {} })
	eq(tool_view("full", "bash", {}, "{oops").c[1].k, "ansi")

	local go = tool_view("full", "read", { path = "/home/u/proj/main.go" }, "[main.go#1A2B]\n10:package main\n11:\n12:func main() {}").c[1]
	eq(go, { k = "code", p = { text = "package main\n\nfunc main() {}", lang = "go", start = 10 }, c = {} })
	local lu = tool_view("full", "read", { path = "lib/x.luau" }, "1:local x = 1\n2:return x").c[1]
	eq(lu.p, { text = "local x = 1\nreturn x", lang = "lua", start = 1 })

	local gap = "10:a\n12:b"
	eq(tool_view("full", "read", { path = "main.go" }, gap).c[1], { k = "ansi", p = { text = gap }, c = {} })
	eq(tool_view("full", "read", { path = "notes.xyz" }, "1:a\n2:b").c[1].k, "ansi")
end)

test("tool head shows the target argument", function()
	local function head(name: string, args: { [string]: any }): { any }
		local t = tool_view("preview", name, args, "x")
		return { t.p.title, t.p.target, t.p.targetKind }
	end
	eq(head("bash", { command = "ls  -la\n  /home/u" }), { "Bash", "ls -la /home/u", "command" })
	eq(head("read", { path = "/home/u/proj/a.go" }), { "Read", "/home/u/proj/a.go", "path" })
	eq(head("grep", { pattern = "TODO" }), { "Grep", "TODO", "pattern" })
	eq(head("edit", { input = "[lib/x.luau#1A2B]\nPUT 1.=1:\n+x" }), { "Edit", "lib/x.luau", "path" })
	eq(head("task", { i = "Writing tests" }), { "Task", "Writing tests", "text" })
	local t = tool_view("preview", "bash", {}, "x")
	eq({ t.p.status, t.p.took }, { "done", 1000 })
end)

test("turn starts carry the turn role", function()
	local v = loaded({
		user("u1", "go"),
		asst("a1", { text("one"), call("c1", "bash") }),
		result("r1", "c1", "bash", "x"),
		asst("a2", { text("two") }),
	})
	local list = find(M.main(v), "col")[2].c
	local roles = {}
	for i, n in list do
		roles[i] = n.p.role or false
	end
	eq(roles, { "periscope.turn", "periscope.turn", false, "periscope.turn" })
end)

test("status placeholders", function()
	local v = M.new("/x", "x")
	local first = M.main(v).c[1]
	eq({ first.k, first.p.label[1].t }, { "spinner", "Loading transcript" })
	v.loaded = true
	eq(M.main(v).c[1].p.spans[1].t, "Nothing in this transcript yet")
	v.error = "denied"
	local spans = M.main(v).c[1].p.spans
	eq({ spans[1].t, spans[2].t }, { "Cannot read transcript: ", "denied" })
end)

check.done()
