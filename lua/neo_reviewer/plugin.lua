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
function M.register_preloads()
    register_loading_module()
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
