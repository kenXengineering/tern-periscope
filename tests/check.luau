-- A tiny test harness: `test` runs a case against a freshly reset tern_stub, `eq` compares
-- deeply, `done` reports and raises (so `luau` exits non-zero) when anything failed.

local stub = require("./tern_stub")

local M = {}

local passed, failed = 0, 0

local function show(v: any, depth: number?): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) ~= "table" then
		return tostring(v)
	end
	if (depth or 0) > 4 then
		return "{…}"
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, (if type(k) == "string" then k else "[" .. tostring(k) .. "]") .. " = " .. show(v[k], (depth or 0) + 1))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

M.show = show

-- Where `a` and `b` differ (nil when equal): a path like `.entries[2].status`.
local function diff(a: any, b: any, path: string): string?
	if type(a) ~= "table" or type(b) ~= "table" then
		if a == b then
			return nil
		end
		return (if path == "" then "value" else path) .. ": expected " .. show(b) .. ", got " .. show(a)
	end
	for k, bv in b do
		local d = diff(a[k], bv, path .. (if type(k) == "string" then "." .. k else "[" .. tostring(k) .. "]"))
		if d then
			return d
		end
	end
	for k, av in a do
		if b[k] == nil then
			return path .. (if type(k) == "string" then "." .. k else "[" .. tostring(k) .. "]") .. ": unexpected " .. show(av)
		end
	end
	return nil
end

-- Deep equality; fails with the first differing path.
function M.eq(actual: any, expected: any, what: string?)
	local d = diff(actual, expected, "")
	if d then
		error((if what then what .. ": " else "") .. d, 2)
	end
end

function M.ok(cond: any, what: string)
	if not cond then
		error(what, 2)
	end
end

function M.test(name: string, fn: () -> ())
	stub.reset()
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. "\n  " .. string.gsub(tostring(err), "\n", "\n  "))
	end
end

function M.done()
	print(string.format("%d passed, %d failed", passed, failed))
	if failed > 0 then
		error("tests failed", 0)
	end
end

return M
