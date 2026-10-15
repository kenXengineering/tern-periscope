--!strict
-- Window half. The list block asks to open a transcript beside it by opening a private
-- URL (host blocks can't place panes themselves); this claims that URL and splits the
-- block that asked, below it.

local util = require("./lib/util")

local PREFIX = "tern-periscope://transcript?"

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	for pair in string.gmatch(string.sub(url, #PREFIX + 1), "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=(.*)$")
		if k ~= nil and v ~= nil then
			out[k] = util.decode(v)
		end
	end
	return out
end

tern.route.link(function(link, cx)
	if string.sub(link.url, 1, #PREFIX) ~= PREFIX then
		return nil
	end
	local q = query(link.url)
	local path = q.path
	if path == nil or path == "" then
		cx:toast("error", "Periscope: no transcript path in link")
		return { handled = true }
	end
	local args = { path, q.label or util.strip_suffix(util.basename(path), ".jsonl") }
	local pane: number? = if link.pane ~= nil then link.pane else nil
	local opened: number? = nil
	if pane ~= nil then
		opened = cx.layout:split(pane, "down", { block = "periscope.transcript", args = args })
	end
	if opened == nil then
		opened = cx:new_block("periscope.transcript", args, "below")
	end
	if opened == nil then
		cx:toast("error", "Periscope: could not open the transcript block")
	end
	return { handled = true }
end)

local function private_use(text: string): boolean
	local ok, found = pcall(function()
		for _, cp in utf8.codes(text) do
			if (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000 then
				return true
			end
		end
		return false
	end)
	return ok and found == true
end

-- Opens a Periscope list beside the focused pane, in that pane's directory. When a pane of the same
-- tab runs omp (its terminal title starts with a private-use status glyph then the session title),
-- the block takes that pane's directory and shows that session.
tern.command({
	id = "show",
	title = "Show Periscope beside",
	icon = "eye",
	keys = { "ctrl+alt+p" },
	run = function(cx)
		local args: { string } = {}
		local focused = cx.session:focused()
		local panes = cx.session:panes()
		local tab: number? = nil
		for _, p in panes do
			if p.pane == focused then
				tab = p.tab
				if p.cwd ~= nil and p.cwd ~= "" then
					args = { p.cwd }
				end
			end
		end
		local omp: PaneInfo? = nil
		for _, p in panes do
			if tab ~= nil and p.tab == tab and p.cwd ~= "" and private_use(p.title) then
				if omp == nil or p.pane == focused then
					omp = p
				end
			end
		end
		if omp ~= nil then
			args = { omp.cwd or "", omp.title }
		end
		if cx:new_block("periscope.list", args, "beside") == nil then
			cx:toast("error", "Periscope: could not open the block")
		end
	end,
})
