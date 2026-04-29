--- @class GitStatus
--- @field branch string
--- @field upstream_branch string
--- @field is_dirty boolean
--- @field up_to_date boolean
--- @field up_to_date_and_clean boolean
--- @field ahead number
--- @field behind number
--- @field stashed number
--- @field conflicted number
--- @field deleted number
--- @field modified number
--- @field renamed number
--- @field staged number
--- @field staged_added number
--- @field staged_deleted number
--- @field staged_modified number
--- @field staged_renamed number
--- @field untracked number

--- @class GitStatusPlugin
local M = {
	--- @class GitStatusOptions
	--- Plugin options
	opts = {
		--- @type (number|false)?
		--- @default 30000
		--- Interval to automatically run `git fetch`, in milliseconds.
		--- Set to `false` to disable auto fetch.
		auto_fetch_interval = 30000,
		--- @type number?
		--- @default 1000
		--- Timeout in milliseconds for `git status` to complete before it is killed.
		git_status_timeout = 1000,
		--- @type boolean?
		--- @default false
		--- Show debug messages
		debug = false,
	},
	--- @type GitStatus?
	--- Current git status, or nil if not available
	status = nil,
	--- @type string?
	--- Current git directory, or nil if not available
	git_dir = nil,
	--- @type uv_fs_event_t?
	git_dir_watcher = nil,
}

-- Variables for debouncing the git status command
local git_status_limit = 1000
local git_status_is_busy = false

--- Print debug messages
--- @param ... string|string[] Either a string, or a list of two strings `{ text, hl_group }`
local function debug_msg(...)
	if not M.opts.debug then
		return
	end

	local chunks = {}
	table.insert(chunks, { os.date("%H:%M:%S") .. " gitstatus: ", "Comment" })
	for _, arg in ipairs({ ... }) do
		if type(arg) == "table" then
			table.insert(chunks, arg)
		elseif type(arg) == "string" then
			table.insert(chunks, { arg })
		end
	end

	vim.defer_fn(function()
		vim.api.nvim_echo(chunks, true, {})
	end, 0)
end

--- Initialize the plugin
--- @param opts GitStatusOptions?
function M.setup(opts)
	-- Merge user options with defaults
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

	-- Set up auto commands
	vim.api.nvim_create_autocmd({ "DirChanged" }, {
		callback = function()
			debug_msg("cwd changed")
			M.get_and_watch_git_dir()
			M.update_git_status()
		end,
	})

	vim.api.nvim_create_autocmd({
		"BufEnter", -- When entering a buffer
		"BufFilePost", -- When a file is renamed
		"BufWritePost", -- When saving a file
		"FileChangedShellPost", -- When a file changes outside of Neovim
	}, {
		callback = function()
			debug_msg("updating git status due to buffer change")
			M.update_git_status()
		end,
	})

	debug_msg("started")

	-- Initialize git status
	M.get_and_watch_git_dir()
	M.update_git_status()
	M.git_fetch()

	-- Auto fetch
	if M.opts.auto_fetch_interval and M.opts.auto_fetch_interval > 0 then
		local interval = M.opts.auto_fetch_interval or 30000
		if interval < 1000 then
			interval = 1000
		end

		local timer = vim.uv.new_timer()
		timer:start(interval, interval, M.git_fetch)
	end
end

local function try_update_status()
	-- We use a hard throttle here: if git status is already running, we do not
	-- run it again even after the previous run finishes. This is intentional to
	-- prevent infinite recursion, since git status will update the .git
	-- directory, and trigger the watcher, which will call this function again.
	if git_status_is_busy then
		return
	end

	git_status_is_busy = true
	vim.system({
		"git",
		"--no-optional-locks",
		"status",
		"--porcelain=2",
		"--branch",
		"--show-stash",
		"--untracked-files=all",
	}, {
		text = true,
		timeout = M.opts.git_status_timeout,
	}, function(obj)
		-- Reset busy flag after delay
		vim.defer_fn(function()
			git_status_is_busy = false
		end, git_status_limit)

		-- Terminated by timeout
		if obj.signal == 15 then
			debug_msg({ "git status timed out", "ErrorMsg" })
			return
		end

		-- Other errors, presume not a git repo
		if obj.code ~= 0 then
			debug_msg({ "git status failed", "ErrorMsg" })
			M.status = nil
			return
		end

		debug_msg("git status successful")
		local status = {
			branch = "",
			upstream_branch = "",
			ahead = 0,
			behind = 0,
			stashed = 0,
			conflicted = 0,
			deleted = 0,
			modified = 0,
			renamed = 0,
			staged = 0,
			staged_added = 0,
			staged_deleted = 0,
			staged_modified = 0,
			staged_renamed = 0,
			untracked = 0,
		}

		-- Parse output
		local lines = vim.split(obj.stdout, "\n")
		for _, line in ipairs(lines) do
			local parts = vim.split(line, " ")
			if parts[1] == "#" then
				if parts[2] == "branch.head" then
					status.branch = parts[3]
				elseif parts[2] == "branch.upstream" then
					status.upstream_branch = parts[3]
				elseif parts[2] == "branch.ab" then
					status.ahead = tonumber(string.sub(parts[3], 2)) or 0
					status.behind = tonumber(string.sub(parts[4], 2)) or 0
				elseif parts[2] == "stash" then
					status.stashed = tonumber(parts[3]) or 0
				end
			elseif parts[1] == "1" then
				-- The second part is the status code XY, where X is the status of the
				-- index and Y is the status of the working directory. X and Y can be
				-- one of the following letters:
				--  - '.' = unmodified
				--  - 'M' = modified
				--  - 'D' = deleted
				--  - 'T' = type changed
				--  - etc. See at:
				-- https://git-scm.com/docs/git-status#_short_format
				local code_x = string.sub(parts[2], 1, 1)
				local code_y = string.sub(parts[2], 2, 2)
				if code_x ~= "." then
					status.staged = status.staged + 1
					if code_x == "A" then
						status.staged_added = status.staged_added + 1
					elseif code_x == "D" then
						status.staged_deleted = status.staged_deleted + 1
					elseif code_x == "M" then
						status.staged_modified = status.staged_modified + 1
					elseif code_x == "R" then
						status.staged_renamed = status.staged_renamed + 1
					end
				end
				if code_y == "M" or code_y == "T" then
					status.modified = status.modified + 1
				elseif code_y == "D" then
					status.deleted = status.deleted + 1
				end
			elseif parts[1] == "2" then
				status.renamed = status.renamed + 1
			elseif parts[1] == "u" then
				status.conflicted = status.conflicted + 1
			elseif parts[1] == "?" then
				status.untracked = status.untracked + 1
			end
		end

		status.is_dirty = status.modified > 0 or status.deleted > 0 or status.renamed > 0 or status.untracked > 0
		status.up_to_date = status.ahead == 0 and status.behind == 0
		status.up_to_date_and_clean = status.up_to_date and not status.is_dirty

		M.status = status
	end)
end

local function try_git_fetch()
	vim.system({
		"git",
		"fetch",
	}, {
		text = true,
	}, function(obj)
		if obj.code == 0 then
			M.update_git_status()
			debug_msg("git fetch successful")
		else
			debug_msg({ "git fetch failed", "ErrorMsg" })
		end
	end)
end

--- Update git status asynchronously, and call the callback when done. When
--- `success` is false, the git status is not updated. This happens when
--- either the git command times out, or another git command is still running.
function M.update_git_status()
	pcall(try_update_status)
end

--- Run git fetch asynchronously
function M.git_fetch()
	debug_msg("running git fetch")
	pcall(try_git_fetch)
end

local function try_get_and_watch_git_dir()
	vim.system({
		"git",
		"rev-parse",
		"--git-dir",
	}, {
		text = true,
	}, function(obj)
		if obj.code == 0 then
			M.git_dir = vim.trim(obj.stdout)
			M.watch_git_dir()

			debug_msg("watching git directory:\n", { M.git_dir, "String" })
		else
			M.git_dir = nil
		end
	end)
end

function M.get_and_watch_git_dir()
	try_get_and_watch_git_dir()
end

--- Watch git directory
function M.watch_git_dir()
	if M.git_dir_watcher and M.git_dir_watcher:is_active() then
		M.git_dir_watcher:stop()
		M.git_dir_watcher:close()
		M.git_dir_watcher = nil
	end

	if not M.git_dir then
		return
	end

	local watcher = vim.uv.new_fs_event()
	if not watcher then
		return
	end

	watcher:start(M.git_dir, {}, function(err, filename)
		if err or not filename then
			return
		end

		debug_msg("updating git status due to file change:\n", { ".git/" .. filename, "String" })
		M.update_git_status()
	end)
	M.git_dir_watcher = watcher
	return watcher
end

return M
