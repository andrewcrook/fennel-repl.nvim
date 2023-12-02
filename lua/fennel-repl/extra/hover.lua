---Convenient high-level REPL features.  These build on top of the primitives
---from lover-level modules and are not provided to the user directly.  The
---user is supposed to access them through mappings instead.
local M = {}

local preview   = vim.lsp.util.open_floating_preview
local instances = require 'fennel-repl.instances'
local op        = require 'fennel-repl.operation'
local cb        = require 'fennel-repl.callback'
local lib       = require 'fennel-repl.lib'


---List of events which close the preview window
---@type string[]
local close_events = {'CursorMoved', 'CursorMovedI', 'InsertCharPre'}
---Maximum floating window width
local max_width = 80
---Maximum floating window height
local max_height = 60


---Focus ID shared among all hover windows in the Fennel REPL
local focus_id = 'fennel_repl_hover_window'


---Helper function which gets the current word under the cursor, including
---adjacent word delimited by full stop characters.  This means we will get
---`string.format` instead of just `format`.
---@return string? word  The word under the cursor if there is any
local function get_word()
	vim.opt.iskeyword:append {'.'}
	local success, word = pcall(vim.fn.expand, '<cword>')
	vim.opt.iskeyword:remove {'.'}
	return success and #word > 0 and word or nil
end

---Helper function which gets the contents of the current selection.  Assumes
---the user is in visual mode or Visual mode.
---@return string text  Contents of the character- or linewise selection
local function get_selection()
	local p1, p2  = vim.fn.getcharpos('v'), vim.fn.getcharpos('.')
	local r1, c1 = p1[2], p1[3]
	local r2, c2 = p2[2], p2[3]
	local start_row, start_col, end_row, end_col
	if r1 < r2 or r1 == r2 and c1 < c2 then
		start_row, end_row = r1, r2
		start_col, end_col = c1, c2
	else
		start_row, end_row = r2, r1
		start_col, end_col = c2, c1
	end
	local text = vim.api.nvim_buf_get_text(0, start_row - 1, start_col - 1, end_row - 1, end_col, {})
	return vim.fn.join(text, '\n')
end


---Open a floating preview window with contents.
---@param lines string[]  The text to display
---@param title (string|string[][])?  Optional window title
local function open_window(lines, title)
	local width = 0
	for _, line in ipairs(lines) do
		local n = vim.fn.strchars(line)
		if n > width then width = n end
	end

	preview(lines, '', {
		title = title,
		width = width,
		height = #lines,
		max_width = max_width,
		max_height = max_height,
		close_events = close_events,
		focus_id = focus_id,
		focusable = true,
		focus = true,
		border = 'single',
	})
end


local function on_eval_error(type, data, traceback)
	local title = string.format('%s error', type)
	local data_lines = vim.split(data, '\\n')
	local   tb_lines = vim.split(traceback, '\\n')
	local width = math.max(
		vim.fn.reduce(vim.tbl_map(vim.fn.strchars, data_lines), math.max, 0),
		vim.fn.reduce(vim.tbl_map(vim.fn.strchars, tb_lines),   math.max, 0))

	table.insert(data_lines, vim.fn['repeat']('─', width))
	vim.list_extend(data_lines, tb_lines)

	open_window(data_lines, {{title, 'Error'}})
end


---Opens documentation for the current symbol under the buffer in a hover
---window.
function M.doc()
	local sym = get_word()
	if not sym then return end

	local jobid = vim.b.fennel_repl_jobid
	if not jobid then return end
	---@type Instance
	local repl  = instances[jobid]
	if not repl then return end

	local msg = op.doc(sym)

	-- Fetch docstring from REPL and add it to the item
	repl.callbacks[msg.id] = coroutine.create(function (response)
		cb.doc(response, function(values)
			open_window(vim.split(values[1], '\\n'))
		end)
	end)
	vim.fn.chansend(jobid, {lib.format_message(msg), ''})
end

function M.eval()
	local mode = vim.fn.mode()
	local code
	if mode == 'v' then
		code = get_selection()
	else
		code = get_word()
	end
	if not code then return end

	local jobid = vim.b.fennel_repl_jobid
	if not jobid then return end
	---@type Instance
	local repl  = instances[jobid]
	if not repl then return end
	-- print('Code: ' .. code)

	---Collected standard output from side effects
	---@type string[]
	local output = {}

	local on_done = function(values)
		local text = table.concat(values, '\t')
		local lines = vim.split(text, '\\n')
		if #output > 0 then
			local width = math.max(
				vim.fn.reduce(vim.tbl_map(vim.fn.strchars,  lines), math.max, 0),
				vim.fn.reduce(vim.tbl_map(vim.fn.strchars, output), math.max, 0))
			table.insert(lines, vim.fn['repeat']('─', width))
			vim.list_extend(lines, output)
		end
		open_window(lines)
	end

	local collect_stdout = function(data)
		table.insert(output, data)
	end

	local msg = op.eval(code)
	repl.callbacks[msg.id] = coroutine.create(function (response)
		cb.eval(response, on_done, collect_stdout, on_eval_error)
	end)
	vim.fn.chansend(jobid, {lib.format_message(msg), ''})
end

return M
