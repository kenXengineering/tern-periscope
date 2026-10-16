-- lib/util.luau: ISO timestamps, durations, one-line text, JSON unescaping, path/URL helpers
-- and running scripts/scan.sh through tern.process.run.

local check = require("./check")
local stub = require("./tern_stub")
local util = require("../lib/util")

check.test("parse_iso: known epoch values", function()
	check.eq(util.parse_iso("1970-01-01T00:00:00Z"), 0)
	check.eq(util.parse_iso("1970-01-01T00:00:00.500Z"), 500)
	check.eq(util.parse_iso("1970-01-01T00:00:00.25Z"), 250)
	check.eq(util.parse_iso("2026-01-01T10:00:01.000Z"), 1767261601000)
	check.eq(util.parse_iso("2000-01-01T00:00:00.000Z"), 946684800000)
end)

check.test("parse_iso: leap day and year boundaries", function()
	check.eq(util.parse_iso("2024-02-29T00:00:00Z"), 1709164800000)
	check.eq(util.parse_iso("2024-03-01T00:00:00Z"), 1709164800000 + 86400000)
	check.eq(util.parse_iso("2025-12-31T23:59:59Z"), 1767225599000)
	check.eq(util.parse_iso("2026-01-01T00:00:00Z"), 1767225600000)
	check.eq(util.parse_iso("1969-12-31T23:59:59Z"), -1000)
end)

check.test("parse_iso: nil and garbage", function()
	check.eq(util.parse_iso(nil), nil)
	check.eq(util.parse_iso(""), nil)
	check.eq(util.parse_iso("yesterday"), nil)
	check.eq(util.parse_iso("2026-01-01"), nil)
end)

check.test("duration: unit boundaries", function()
	check.eq(util.duration(59999), "59s")
	check.eq(util.duration(60000), "1m 0s")
	check.eq(util.duration(83000), "1m 23s")
	check.eq(util.duration(3599999), "59m 59s")
	check.eq(util.duration(3600000), "1h 0m")
	check.eq(util.duration(23 * 3600000), "23h 0m")
	check.eq(util.duration(86399999), "23h 59m")
	check.eq(util.duration(86400000), "1d 0h")
	check.eq(util.duration(-5000), "0s")
end)

check.test("oneline: collapses whitespace and trims", function()
	check.eq(util.oneline("  fix \n\t the   bug  ", 100), "fix the bug")
end)

check.test("oneline: cuts at max UTF-8 characters with an ellipsis", function()
	local s = "héllo wörld" -- 11 characters, 13 bytes
	check.eq(util.oneline(s, 11), s, "exact length is kept")
	check.eq(util.oneline(s, 10), "héllo wör…")
	check.eq(util.oneline("abcdef", 3), "ab…")
end)

check.test("unescape: JSON escapes", function()
	check.eq(util.unescape([[a\nb\tc\"d\\e\/f]]), 'a\nb\tc"d\\e/f')
	check.eq(util.unescape([[x\by\fz]]), "xyz")
	check.eq(util.unescape("plain"), "plain")
end)

check.test("encode/decode: paths round-trip, slashes stay", function()
	check.eq(util.encode("/home/u/my dir/a.txt"), "/home/u/my%20dir/a.txt")
	check.eq(util.encode("/home/u/é"), "/home/u/%C3%A9")
	local path = "/home/u/a b/q?x&y%z#h=1/é ü.jsonl"
	local encoded = util.encode(path)
	check.ok(not string.find(encoded, "[ ?&#=]"), "reserved characters encoded: " .. encoded)
	check.eq(util.decode(encoded), path)
end)

check.test("basename and dirname", function()
	check.eq(util.basename("/home/u/s/Agent.jsonl"), "Agent.jsonl")
	check.eq(util.basename("Agent.jsonl"), "Agent.jsonl")
	check.eq(util.dirname("/home/u/s/Agent.jsonl"), "/home/u/s")
	check.eq(util.dirname("Agent.jsonl"), ".")
end)

check.test("strip_suffix", function()
	check.eq(util.strip_suffix("a.jsonl", ".jsonl"), "a")
	check.eq(util.strip_suffix("a.json", ".jsonl"), "a.json")
	check.eq(util.strip_suffix(".jsonl", ".jsonl"), "")
	check.eq(util.strip_suffix("l", ".jsonl"), "l")
end)

local function scan(args: { string }): (string?, string?)
	local out, err
	util.scan(args, function(o, e)
		out, err = o, e
	end)
	return out, err
end

check.test("scan: runs scan.sh from the plugin dir and returns stdout", function()
	stub.run = function()
		return { status = 0, stdout = "now 5\n", stderr = "" }
	end
	local out, err = scan({ "sizes", "/home/u/s" })
	check.eq(stub.calls, { { "sh", "/plugin/scripts/scan.sh", "sizes", "/home/u/s" } })
	check.eq(out, "now 5\n")
	check.eq(err, nil)
end)

check.test("scan: failure reports stderr, else the exit status", function()
	stub.run = function()
		return { status = 2, stdout = "partial", stderr = "no such dir" }
	end
	local out, err = scan({ "sizes" })
	check.eq(out, nil)
	check.eq(err, "no such dir")
	stub.run = function()
		return { status = 3, stdout = "", stderr = "" }
	end
	out, err = scan({ "sizes" })
	check.eq(out, nil)
	check.eq(err, "scan.sh exited 3")
end)

check.done()
