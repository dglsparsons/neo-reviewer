---@class NRPluginModule
local M = {}

---@return nil
local function register_loading_module()
    if package.preload["neo_reviewer.ui.loading"] then
        return
    end

    package.preload["neo_reviewer.ui.loading"] = function()
        ---@class NRLoadingUIModule
        local loading = {}

        local loading_bufnr = nil
        local loading_timer = nil
        local loading_frame_index = 1
        local loading_frames = { ".", "..", "..." }

        ---@class NRLoadingOpenOpts
        ---@field title string
        ---@field message? string
        ---@field detail? string
        ---@field focus? boolean
        ---@field interval_ms? integer

        ---@type NRLoadingOpenOpts?
        local current_opts = nil

        ---@param timer integer?
        ---@return integer?
        local function stop_timer(timer)
            if timer then
                pcall(vim.fn.timer_stop, timer)
            end
            return nil
        end

        ---@return integer
        local function ensure_buffer()
            if loading_bufnr and vim.api.nvim_buf_is_valid(loading_bufnr) then
                return loading_bufnr
            end

            loading_bufnr = vim.api.nvim_create_buf(false, true)
            vim.bo[loading_bufnr].buftype = "nofile"
            vim.bo[loading_bufnr].bufhidden = "hide"
            vim.bo[loading_bufnr].swapfile = false
            vim.bo[loading_bufnr].modifiable = false
            vim.bo[loading_bufnr].filetype = "neo-reviewer-loading"

            return loading_bufnr
        end

        ---@param bufnr integer|nil
        ---@return integer|nil
        local function get_window_for_buffer(bufnr)
            if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
                return nil
            end

            local winid = vim.fn.bufwinid(bufnr)
            if winid == -1 then
                return nil
            end

            return winid
        end

        ---@return integer|nil
        local function find_split_base_window()
            local best_winid = nil
            local best_height = -1

            for _, winid in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_is_valid(winid) then
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    local filetype = vim.bo[bufnr].filetype
                    if
                        filetype ~= "neo-reviewer-ai"
                        and filetype ~= "neo-reviewer-ai-nav"
                        and filetype ~= "neo-reviewer-walkthrough"
                        and filetype ~= "neo-reviewer-walkthrough-nav"
                        and filetype ~= "neo-reviewer-loading"
                    then
                        local height = vim.api.nvim_win_get_height(winid)
                        if height > best_height then
                            best_height = height
                            best_winid = winid
                        end
                    end
                end
            end

            return best_winid
        end

        ---@param winid integer
        ---@return nil
        local function configure_window(winid)
            vim.wo[winid].number = false
            vim.wo[winid].relativenumber = false
            vim.wo[winid].signcolumn = "no"
            vim.wo[winid].foldcolumn = "0"
            vim.wo[winid].cursorline = false
            vim.wo[winid].wrap = true
            vim.wo[winid].winfixheight = false
            vim.wo[winid].winfixwidth = false
        end

        ---@param height integer
        ---@param focus boolean
        ---@return integer, integer
        local function ensure_open(height, focus)
            local bufnr = ensure_buffer()
            local winid = get_window_for_buffer(bufnr)
            local current_win = vim.api.nvim_get_current_win()

            if not winid then
                local split_win = find_split_base_window()
                if split_win and vim.api.nvim_win_is_valid(split_win) then
                    vim.api.nvim_set_current_win(split_win)
                end
                vim.cmd("botright " .. tostring(height) .. "split")
                winid = vim.api.nvim_get_current_win()
                vim.api.nvim_set_current_buf(bufnr)
            end

            ---@cast winid integer
            configure_window(winid)

            if not focus and vim.api.nvim_win_is_valid(current_win) then
                vim.api.nvim_set_current_win(current_win)
            end

            return winid, bufnr
        end

        ---@param lines string[]
        ---@param max_width integer
        ---@return string[]
        local function wrap_lines(lines, max_width)
            ---@type string[]
            local wrapped = {}
            for _, line in ipairs(lines) do
                if #line > max_width then
                    local remaining = line
                    while #remaining > 0 do
                        local chunk = remaining:sub(1, max_width)
                        local space_pos = chunk:reverse():find(" ")
                        if space_pos and #remaining > max_width then
                            chunk = chunk:sub(1, max_width - space_pos + 1)
                        end
                        table.insert(wrapped, chunk)
                        remaining = remaining:sub(#chunk + 1):gsub("^%s+", "")
                    end
                else
                    table.insert(wrapped, line)
                end
            end
            return wrapped
        end

        ---@param bufnr integer
        ---@param lines string[]
        ---@return nil
        local function set_lines(bufnr, lines)
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.bo[bufnr].modifiable = false
        end

        ---@param line_count integer
        ---@return integer
        local function get_target_height(line_count)
            local max_height = math.max(1, math.floor((vim.o.lines - 4) / 3))
            return math.max(1, math.min(line_count, max_height))
        end

        ---@return nil
        local function render_current()
            if not current_opts then
                return
            end

            local winid, bufnr = ensure_open(1, current_opts.focus or false)
            local width = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_width(winid) or vim.o.columns
            local suffix = loading_frames[loading_frame_index]
            local lines = { current_opts.title .. suffix }

            if current_opts.message and current_opts.message ~= "" then
                table.insert(lines, "")
                table.insert(lines, current_opts.message)
            end

            if current_opts.detail and current_opts.detail ~= "" then
                table.insert(lines, "")
                table.insert(lines, current_opts.detail)
            end

            local wrapped = wrap_lines(lines, math.max(20, width - 4))
            set_lines(bufnr, wrapped)

            if vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_set_height(winid, get_target_height(#wrapped))
            end
        end

        ---@return boolean
        function loading.is_open()
            return get_window_for_buffer(loading_bufnr) ~= nil
        end

        ---@param opts NRLoadingOpenOpts
        ---@return nil
        function loading.show(opts)
            current_opts = opts
            loading_frame_index = 1
            loading_timer = stop_timer(loading_timer)
            render_current()

            local interval_ms = math.max(100, opts.interval_ms or 500)
            loading_timer = vim.fn.timer_start(interval_ms, function()
                if not loading.is_open() then
                    loading.close()
                    return
                end

                loading_frame_index = (loading_frame_index % #loading_frames) + 1
                render_current()
            end, { ["repeat"] = -1 })
        end

        ---@return boolean
        function loading.close()
            loading_timer = stop_timer(loading_timer)
            current_opts = nil

            local winid = get_window_for_buffer(loading_bufnr)
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
                return true
            end

            return false
        end

        return loading
    end
end

---@return nil
local function register_neotree_module()
    if package.preload["neo_reviewer.neotree"] then
        return
    end

    package.preload["neo_reviewer.neotree"] = function()
        ---@class NRNeoTreeModule
        local neotree = {}

        local source_name = "review"

        ---@param winid integer|nil
        ---@return boolean
        local function is_visible_review_window(winid)
            if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
                return false
            end

            local bufnr = vim.api.nvim_win_get_buf(winid)
            if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "neo-tree" then
                return false
            end

            -- Neo-tree source state can outlive the currently displayed buffer.
            -- Only treat the review tree as open when the visible buffer is actually the review source.
            return vim.b[bufnr].neo_tree_source == source_name
        end

        ---@return table|nil
        local function load_manager()
            local ok, manager = pcall(require, "neo-tree.sources.manager")
            if not ok then
                return nil
            end
            return manager
        end

        ---@return table|nil
        local function load_command()
            local ok, command = pcall(require, "neo-tree.command")
            if not ok then
                return nil
            end
            return command
        end

        ---@return boolean
        function neotree.is_open()
            local manager = load_manager()
            if not manager or type(manager.get_state) ~= "function" then
                return false
            end

            local ok, state = pcall(manager.get_state, source_name)
            if not ok or type(state) ~= "table" then
                return false
            end

            return is_visible_review_window(state.winid)
        end

        ---@return boolean
        function neotree.refresh()
            local manager = load_manager()
            if not manager or type(manager.refresh) ~= "function" then
                return false
            end

            local ok = pcall(manager.refresh, source_name)
            return ok
        end

        ---@return boolean
        function neotree.open()
            local command = load_command()
            if not command or type(command.execute) ~= "function" then
                return false
            end

            local config = require("neo_reviewer.config")
            local ok = pcall(command.execute, {
                source = source_name,
                position = config.values.neo_tree.position,
            })
            return ok
        end

        ---@param opts? { open?: boolean }
        ---@return boolean
        function neotree.on_review_changed(opts)
            opts = opts or {}
            local config = require("neo_reviewer.config")
            local should_open = opts.open
            if should_open == nil then
                should_open = config.values.neo_tree.open_on_review
            end

            if neotree.is_open() then
                return neotree.refresh()
            end

            if should_open then
                return neotree.open()
            end

            return false
        end

        ---@return boolean
        function neotree.on_review_cleared()
            if not neotree.is_open() then
                return false
            end

            return neotree.refresh()
        end

        return neotree
    end
end

---@return nil
local function register_neotree_review_source()
    if package.preload["neo_reviewer.sources.review"] then
        return
    end

    package.preload["neo_reviewer.sources.review"] = function()
        local renderer = require("neo-tree.ui.renderer")

        ---@class NRNeoTreeReviewSource
        local source = {
            name = "review",
            display_name = "Review",
        }

        ---@param root string|nil
        ---@param path string
        ---@return string
        local function join_path(root, path)
            if not root or root == "" then
                return path
            end
            if path == "" then
                return root
            end
            return root:gsub("/+$", "") .. "/" .. path
        end

        ---@param path string
        ---@return string
        local function basename(path)
            return vim.fn.fnamemodify(path, ":t")
        end

        ---@param status string|nil
        ---@return string|nil
        local function git_status_for_review_status(status)
            return ({
                add = "A",
                added = "A",
                deleted = "D",
                modified = "M",
                removed = "D",
                renamed = "R",
            })[status]
        end

        ---@param existing string|nil
        ---@param status string
        ---@return string
        local function merge_git_status(existing, status)
            local priority = {
                D = 4,
                R = 3,
                M = 2,
                A = 1,
            }

            if not existing then
                return status
            end

            if (priority[status] or 0) > (priority[existing] or 0) then
                return status
            end

            return existing
        end

        ---@param root_path string|nil
        ---@param path string
        ---@return boolean
        local function is_within_root(root_path, path)
            if not root_path or root_path == "" then
                return true
            end

            return path == root_path or path:sub(1, #root_path + 1) == root_path .. "/"
        end

        ---@param review NRReview|nil
        ---@return table<string, string>|nil
        local function build_git_status_lookup(review)
            if not review or #(review.files or {}) == 0 then
                return nil
            end

            ---@type table<string, string>
            local lookup = {}
            local root_path = review.git_root

            for _, file in ipairs(review.files or {}) do
                local status = git_status_for_review_status(file.status)
                if status then
                    local file_path = join_path(root_path, file.path)
                    lookup[file_path] = status

                    local parent_path = vim.fn.fnamemodify(file_path, ":h")
                    while parent_path ~= "." and parent_path ~= "" and is_within_root(root_path, parent_path) do
                        lookup[parent_path] = merge_git_status(lookup[parent_path], status)
                        if parent_path == root_path then
                            break
                        end

                        local next_parent = vim.fn.fnamemodify(parent_path, ":h")
                        if next_parent == parent_path then
                            break
                        end
                        parent_path = next_parent
                    end
                end
            end

            if next(lookup) == nil then
                return nil
            end

            return lookup
        end

        ---@param review NRReview|nil
        ---@return table[]
        local function build_nodes(review)
            if not review or #(review.files or {}) == 0 then
                return {}
            end

            ---@type table[]
            local root_nodes = {}
            ---@type table<string, table>
            local dir_lookup = {}

            for _, file in ipairs(review.files or {}) do
                local parent_nodes = root_nodes
                local parent_path = ""
                local parts = vim.split(file.path, "/", { plain = true })

                for index = 1, math.max(#parts - 1, 0) do
                    local part = parts[index]
                    parent_path = parent_path == "" and part or (parent_path .. "/" .. part)

                    local directory = dir_lookup[parent_path]
                    if not directory then
                        directory = {
                            id = "dir:" .. parent_path,
                            name = part,
                            type = "directory",
                            path = join_path(review.git_root, parent_path),
                            loaded = true,
                            _is_expanded = true,
                            children = {},
                        }
                        dir_lookup[parent_path] = directory
                        table.insert(parent_nodes, directory)
                    end

                    parent_nodes = directory.children
                end

                table.insert(parent_nodes, {
                    id = "file:" .. file.path,
                    name = basename(file.path),
                    type = "file",
                    path = join_path(review.git_root, file.path),
                })
            end

            local function sort_nodes(nodes)
                table.sort(nodes, function(left, right)
                    if left.type ~= right.type then
                        return left.type == "directory"
                    end
                    return left.name:lower() < right.name:lower()
                end)

                for _, node in ipairs(nodes) do
                    if node.type == "directory" then
                        sort_nodes(node.children or {})
                    end
                end
            end

            sort_nodes(root_nodes)
            return root_nodes
        end

        ---@param review NRReview|nil
        ---@param state table
        ---@return table[]
        local function build_tree(review, state)
            local nodes = build_nodes(review)
            if not review or not review.git_root or review.git_root == "" then
                return nodes
            end

            return {
                {
                    id = review.git_root,
                    name = vim.fn.fnamemodify(review.git_root, ":~"),
                    type = "directory",
                    path = review.git_root,
                    loaded = true,
                    _is_expanded = true,
                    search_pattern = state.search_pattern,
                    children = nodes,
                },
            }
        end

        ---@param state table
        ---@return nil
        function source.navigate(state)
            local review = require("neo_reviewer.state").get_review()
            state.git_status_lookup = build_git_status_lookup(review)
            if review and review.git_root then
                state.path = review.git_root
            end
            renderer.show_nodes(build_tree(review, state), state)
        end

        ---@param _ table
        ---@return nil
        function source.setup(_) end

        return source
    end

    package.preload["neo_reviewer.sources.review.components"] = function()
        return require("neo-tree.sources.filesystem.components")
    end

    package.preload["neo_reviewer.sources.review.commands"] = function()
        local common_commands = require("neo-tree.sources.common.commands")
        local manager = require("neo-tree.sources.manager")

        ---@class NRNeoTreeReviewCommands
        local commands = vim.tbl_deep_extend("force", common_commands, {})

        ---@param state table
        ---@return nil
        function commands.refresh(state)
            manager.refresh("review", state)
        end

        return commands
    end
end

---@return nil
function M.register_preloads()
    register_loading_module()
    register_neotree_module()
    register_neotree_review_source()
end

M.register_preloads()

---@return nil
function M.setup()
    M.register_preloads()

    vim.api.nvim_create_autocmd("VimEnter", {
        callback = function()
            if vim.fn.argc() > 0 then
                local arg = vim.fn.argv(0)
                if type(arg) == "string" and arg:match("github%.com/.+/pull/%d+") then
                    vim.defer_fn(function()
                        require("neo_reviewer").open_url(arg)
                    end, 100)
                end
            end
        end,
        once = true,
    })
end

return M
