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

-- Opens a Periscope list beside the focused pane, in that pane's directory.
tern.command({
	id = "show",
	title = "Show Periscope beside",
	icon = "eye",
	keys = { "ctrl+alt+s" },
	run = function(cx)
		local args: { string } = {}
		local focused = cx.session:focused()
		if focused ~= nil then
			for _, p in cx.session:panes() do
				local cwd = p.cwd
				if p.pane == focused and cwd ~= nil and cwd ~= "" then
					args = { cwd }
				end
			end
		end
		if cx:new_block("periscope.list", args, "beside") == nil then
			cx:toast("error", "Periscope: could not open the block")
		end
	end,
})
