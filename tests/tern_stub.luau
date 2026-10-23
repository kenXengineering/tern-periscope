-- A fake `tern` global for running lib/*.luau under the stock luau CLI. tests/run.sh puts
-- `local tern = require("../tests/tern_stub").tern` on line 1 of each copied module, so the
-- modules and the tests share this one instance. Tests drive it through the fields below;
-- tests/check.luau calls `reset()` before every test.

local T = {}

T.env = {} :: { [string]: string } -- tern.getenv reads this
T.clock = 0 -- tern.now() returns this (monotonic ms)
-- tern.process.run calls this with argv and opts and hands the result to the callback right away.
T.run = nil :: ((argv: { string }, opts: any) -> { status: number, stdout: string, stderr: string })?
T.calls = {} :: { { string } } -- argv of every tern.process.run
T.timers = {} :: { () -> () } -- queued tern.timer callbacks; `flush()` runs them

function T.reset()
	T.env = {}
	T.clock = 0
	T.run = nil
	T.calls = {}
	T.timers = {}
end

-- Runs queued timers, including ones queued while flushing.
function T.flush()
	while #T.timers > 0 do
		table.remove(T.timers, 1)()
	end
end

-- JSON ------------------------------------------------------------------------------------
-- Enough of tern.json.decode for transcripts: raises on malformed or truncated input; null
-- object members are dropped, like Tern's.

local function decode(text: string): any
	local pos = 1

	local function fail(what: string): never
		error(string.format("json: %s at %d", what, pos), 0)
	end

	local function ws()
		pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
	end

	local value: () -> any

	local function str(): string
		pos += 1 -- opening quote
		local out: { string } = {}
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				fail("unterminated string")
			elseif c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
				if simple ~= nil then
					table.insert(out, simple)
					pos += 2
				elseif e == "u" then
					local cp = tonumber(string.sub(text, pos + 2, pos + 5), 16) or fail("bad \\u escape")
					pos += 6
					if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
						local lo = tonumber(string.sub(text, pos + 2, pos + 5), 16) or fail("bad \\u escape")
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
						pos += 6
					end
					table.insert(out, utf8.char(cp))
				else
					fail("bad escape")
				end
			else
				local run = string.match(text, '^[^"\\]+', pos) :: string
				table.insert(out, run)
				pos += #run
			end
		end
	end

	function value(): any
		ws()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			ws()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				ws()
				if string.sub(text, pos, pos) ~= '"' then
					fail("expected key")
				end
				local k = str()
				ws()
				if string.sub(text, pos, pos) ~= ":" then
					fail("expected ':'")
				end
				pos += 1
				obj[k] = value()
				ws()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "}" then
					return obj
				elseif sep ~= "," then
					fail("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			ws()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			local n = 0
			while true do
				n += 1
				arr[n] = value()
				ws()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "]" then
					return arr
				elseif sep ~= "," then
					fail("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return nil
		end
		local num = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if num == nil or tonumber(num) == nil then
			fail("unexpected input")
		end
		pos += #num
		return tonumber(num)
	end

	local v = value()
	ws()
	if pos <= #text then
		fail("trailing input")
	end
	return v
end

-- UI --------------------------------------------------------------------------------------
-- Builders return plain `{ k, p, c }` tables (Tern's wire shape) so tests can inspect a view.

local function node(kind: string, props: { [string]: any }?, children: { any }?): any
	return { k = kind, p = props or {}, c = children or {} }
end

local ui = setmetatable({
	node = node,
	span = function(t: string, s: string?)
		return { t = t, s = s }
	end,
	text = function(spans: { any })
		return node("text", { spans = spans })
	end,
	card = function(head: { any }, children: { any })
		return node("card", { head = head }, children)
	end,
	section = function(head: { any }, children: { any })
		return node("section", { head = head }, children)
	end,
	badge = function(t: string, tone: string)
		return node("badge", { text = t, tone = tone })
	end,
	md = function(text: string)
		return node("md", { text = text })
	end,
	code = function(text: string, lang: string?, start: number?)
		return node("code", { text = text, lang = lang, start = start })
	end,
	diff = function(text: string, path: string?)
		return node("diff", { text = text, path = path })
	end,
}, {
	-- col, row, lines and any other container: `(children) -> node`
	__index = function(_, kind: string)
		return function(children: { any }?)
			return node(kind, {}, children)
		end
	end,
})

T.tern = {
	getenv = function(name: string): string?
		return T.env[name]
	end,
	now = function(): number
		return T.clock
	end,
	timer = function(_ms: number, fn: () -> ())
		table.insert(T.timers, fn)
		return {}
	end,
	json = { decode = decode },
	plugin = { dir = "/plugin" },
	process = {
		run = function(argv: { string }, opts: any, cb: (any) -> ())
			table.insert(T.calls, argv)
			local run = T.run
			if run == nil then
				error("tern.process.run called without tern_stub.run: " .. table.concat(argv, " "))
			end
			cb(run(argv, opts))
		end,
	},
	parse = {
		json_tree = function(text: string): any
			local ok = pcall(decode, text)
			return if ok then node("json_tree", { text = text }) else nil
		end,
	},
	ui = ui,
}

return T
