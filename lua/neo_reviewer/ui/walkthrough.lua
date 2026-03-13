---@class NRWalkthroughUIModule
local M = {}

---@return NRPluginModule
local function load_plugin_module()
    local source = debug.getinfo(load_plugin_module, "S").source
    if type(source) ~= "string" or source == "" then
        error("neo_reviewer.ui.walkthrough source path not found")
    end
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end

    local plugin_dir = vim.fn.fnamemodify(vim.fn.fnamemodify(source, ":h"), ":h")
    local plugin_path = plugin_dir .. "/plugin.lua"

    local chunk, load_err = loadfile(plugin_path)
    if not chunk then
        error(load_err)
    end

    local ok, plugin = pcall(chunk)
    if not ok then
        error(plugin)
    end

    if type(plugin) ~= "table" then
        error("neo_reviewer.plugin did not return a module table")
    end

    package.loaded["neo_reviewer.plugin"] = plugin
    return plugin
end

---@param plugin unknown
---@return boolean
local function register_loading_with(plugin)
    if type(plugin) ~= "table" or type(plugin.register_preloads) ~= "function" then
        return false
    end

    plugin.register_preloads()
    return package.preload["neo_reviewer.ui.loading"] ~= nil
end

---@return nil
local function ensure_loading_preload()
    if package.preload["neo_reviewer.ui.loading"] then
        return
    end

    local plugin = package.loaded["neo_reviewer.plugin"]
    if register_loading_with(plugin) then
        return
    end

    plugin = load_plugin_module()
    if register_loading_with(plugin) then
        return
    end

    error("neo_reviewer.plugin did not expose register_preloads")
end

---@return NRLoadingUIModule
local function get_loading_ui()
    ensure_loading_preload()
    return require("neo_reviewer.ui.loading")
end

local ns = vim.api.nvim_create_namespace("nr_walkthrough")

local detail_bufnr = nil
local navigator_bufnr = nil
local last_step_index = nil
local last_anchor_index = nil

---@type table<integer, integer>
local navigator_line_steps = {}

---@type table<integer, boolean>
local highlighted_buffers = {}

---@class NRWalkthroughOpenOpts
---@field jump_to_first? boolean

---@return nil
local function define_highlights()
    -- Ask highlights should guide attention without reading like a diff overlay.
    vim.api.nvim_set_hl(0, "NRWalkthroughHeading", { bold = true })
    vim.api.nvim_set_hl(0, "NRWalkthroughActiveStep", { bg = "#28343d" })
    vim.api.nvim_set_hl(0, "NRWalkthroughMuted", { link = "Comment" })
    vim.api.nvim_set_hl(0, "NRWalkthroughRange", { bg = "#31404a" })
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

---@param text string
---@return string[]
local function split_lines(text)
    return vim.split(text, "\n", { plain = true })
end

---@param text string
---@param max_lines integer
---@return string[]
local function summarize_overview(text, max_lines)
    local summary = {}
    for _, line in ipairs(split_lines(text)) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            table.insert(summary, trimmed)
        end
        if #summary == max_lines then
            break
        end
    end
    return summary
end

---@param text string
---@param max_width integer
---@return string
local function append_ellipsis(text, max_width)
    if max_width <= 3 then
        return text:sub(1, max_width)
    end
    if #text > max_width - 3 then
        return text:sub(1, max_width - 3) .. "..."
    end
    return text
end

---@param walkthrough NRWalkthrough
---@param step NRWalkthroughStep
---@return string[]
local function collect_step_files(walkthrough, step)
    ---@type string[]
    local files = {}
    ---@type table<string, boolean>
    local seen = {}

    for _, anchor in ipairs(step.anchors or {}) do
        if anchor.file ~= "" and not seen[anchor.file] then
            table.insert(files, anchor.file)
            seen[anchor.file] = true
        end
    end

    if walkthrough.mode == "conceptual" and #files == 0 then
        return {}
    end

    return files
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@param width integer
---@return string[]
local function build_navigator_lines(walkthrough, step_index, width)
    local available_width = math.max(16, width - 2)

    ---@type string[]
    local lines = {}
    navigator_line_steps = {}

    table.insert(lines, "Overview")
    local overview_lines = wrap_lines(summarize_overview(walkthrough.overview, 2), available_width)
    for _, line in ipairs(overview_lines) do
        table.insert(lines, line)
    end

    if #walkthrough.steps == 0 then
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #walkthrough.steps))

    table.insert(lines, "")
    table.insert(lines, string.format("Steps (%d)", #walkthrough.steps))

    ---@param text string
    ---@param first_prefix string
    ---@param continuation_prefix string
    ---@param max_lines integer
    ---@return string[]
    local function wrap_prefixed(text, first_prefix, continuation_prefix, max_lines)
        local content_width = math.max(10, available_width - #first_prefix)
        local wrapped = wrap_lines({ text }, content_width)
        if #wrapped > max_lines then
            wrapped = { unpack(wrapped, 1, max_lines) }
            wrapped[max_lines] = append_ellipsis(wrapped[max_lines], content_width)
        end

        ---@type string[]
        local prefixed = {}
        for line_index, line in ipairs(wrapped) do
            local prefix = line_index == 1 and first_prefix or continuation_prefix
            table.insert(prefixed, prefix .. line)
        end
        return prefixed
    end

    for current_index, step in ipairs(walkthrough.steps) do
        local indicator = current_index == clamped_index and "> " or "  "
        local title_prefix = string.format("%s%d. ", indicator, current_index)
        local continuation_prefix = string.rep(" ", #title_prefix)
        local title_lines = wrap_prefixed(step.title, title_prefix, continuation_prefix, 2)

        for _, line in ipairs(title_lines) do
            table.insert(lines, line)
            navigator_line_steps[#lines] = current_index
        end
    end

    return lines
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return string[]
local function build_detail_lines(walkthrough, step_index)
    ---@type string[]
    local lines = {}

    if #walkthrough.steps == 0 then
        table.insert(lines, "Overview")
        for _, line in ipairs(split_lines(walkthrough.overview)) do
            table.insert(lines, line)
        end
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps provided.")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #walkthrough.steps))
    local step = walkthrough.steps[clamped_index]
    local files = collect_step_files(walkthrough, step)
    local anchor_count = #(step.anchors or {})

    table.insert(lines, string.format("Step %d/%d", clamped_index, #walkthrough.steps))
    table.insert(lines, step.title)
    table.insert(
        lines,
        string.format(
            "%d anchor%s across %d file%s",
            anchor_count,
            anchor_count == 1 and "" or "s",
            #files,
            #files == 1 and "" or "s"
        )
    )
    table.insert(lines, "")
    table.insert(lines, "Details")
    for _, line in ipairs(split_lines(step.explanation)) do
        table.insert(lines, line)
    end

    if #files > 0 then
        table.insert(lines, "")
        table.insert(lines, "Files In This Step")
        for _, file_path in ipairs(files) do
            table.insert(lines, "- " .. file_path)
        end
    end

    return lines
end

---@param bufnr integer
---@param lines string[]
---@return nil
local function set_lines(bufnr, lines)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

---@param bufnr integer
---@param line_index integer
---@param group string
---@return nil
local function highlight_line(bufnr, line_index, group)
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_index - 1, 0, {
        line_hl_group = group,
        priority = 90,
    })
end

---@param bufnr integer
---@param lines string[]
---@param heading_lines integer[]
---@param active_lines integer[]
---@return nil
local function highlight_navigator(bufnr, lines, heading_lines, active_lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    define_highlights()

    for _, line_index in ipairs(heading_lines) do
        if lines[line_index] then
            highlight_line(bufnr, line_index, "NRWalkthroughHeading")
        end
    end

    for _, line_index in ipairs(active_lines) do
        if lines[line_index] then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line_index - 1, 0, {
                line_hl_group = "NRWalkthroughActiveStep",
                priority = 100,
            })
        end
    end
end

---@param bufnr integer
---@param lines string[]
---@return nil
local function highlight_detail(bufnr, lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    define_highlights()

    for line_index, line in ipairs(lines) do
        if line == "Overview" or line == "Details" or line == "Files In This Step" then
            highlight_line(bufnr, line_index, "NRWalkthroughHeading")
        elseif line:match("^Step %d+/%d+$") then
            highlight_line(bufnr, line_index, "NRWalkthroughMuted")
        end
    end

    if lines[1] and lines[1]:match("^Step %d+/%d+$") and lines[2] then
        highlight_line(bufnr, 2, "NRWalkthroughHeading")
    end
end

---@return integer
local function ensure_detail_buffer()
    if detail_bufnr and vim.api.nvim_buf_is_valid(detail_bufnr) then
        return detail_bufnr
    end

    detail_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[detail_bufnr].buftype = "nofile"
    vim.bo[detail_bufnr].bufhidden = "hide"
    vim.bo[detail_bufnr].swapfile = false
    vim.bo[detail_bufnr].modifiable = false
    vim.bo[detail_bufnr].filetype = "neo-reviewer-walkthrough"

    return detail_bufnr
end

---@return integer
local function ensure_navigator_buffer()
    if navigator_bufnr and vim.api.nvim_buf_is_valid(navigator_bufnr) then
        return navigator_bufnr
    end

    navigator_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[navigator_bufnr].buftype = "nofile"
    vim.bo[navigator_bufnr].bufhidden = "hide"
    vim.bo[navigator_bufnr].swapfile = false
    vim.bo[navigator_bufnr].modifiable = false
    vim.bo[navigator_bufnr].filetype = "neo-reviewer-walkthrough-nav"

    vim.keymap.set("n", "<CR>", function()
        M.select_current_step()
    end, { buffer = navigator_bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = navigator_bufnr, nowait = true, silent = true })

    return navigator_bufnr
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

---@return boolean
local function close_windows()
    local closed = false

    local navigator_winid = get_window_for_buffer(navigator_bufnr)
    if navigator_winid and vim.api.nvim_win_is_valid(navigator_winid) then
        vim.api.nvim_win_close(navigator_winid, true)
        closed = true
    end

    local detail_winid = get_window_for_buffer(detail_bufnr)
    if detail_winid and vim.api.nvim_win_is_valid(detail_winid) then
        vim.api.nvim_win_close(detail_winid, true)
        closed = true
    end

    return closed
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
---@param wrap boolean
---@return nil
local function configure_window(winid, wrap)
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].cursorline = false
    vim.wo[winid].wrap = wrap
    vim.wo[winid].winfixheight = false
    vim.wo[winid].winfixwidth = false
end

---@param height integer
---@param nav_width integer
---@param focus boolean
---@return integer, integer
local function ensure_open_with_layout(height, nav_width, focus)
    local detail_buf = ensure_detail_buffer()
    local navigator_buf = ensure_navigator_buffer()
    local detail_winid = get_window_for_buffer(detail_buf)
    local navigator_winid = get_window_for_buffer(navigator_buf)

    if (detail_winid and not navigator_winid) or (navigator_winid and not detail_winid) then
        close_windows()
        detail_winid = nil
        navigator_winid = nil
    end

    local current_win = vim.api.nvim_get_current_win()

    if not detail_winid then
        local split_win = find_split_base_window()
        if split_win and vim.api.nvim_win_is_valid(split_win) then
            vim.api.nvim_set_current_win(split_win)
        end
        vim.cmd("botright " .. tostring(height) .. "split")
        detail_winid = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_buf(detail_buf)

        vim.cmd("leftabove " .. tostring(nav_width) .. "vsplit")
        navigator_winid = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_buf(navigator_buf)

        detail_winid = get_window_for_buffer(detail_buf)
    elseif not navigator_winid then
        vim.api.nvim_set_current_win(detail_winid)
        vim.cmd("leftabove " .. tostring(nav_width) .. "vsplit")
        navigator_winid = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_buf(navigator_buf)
        detail_winid = get_window_for_buffer(detail_buf)
    end

    if not detail_winid or not navigator_winid then
        error("failed to open walkthrough windows")
    end

    configure_window(navigator_winid, false)
    configure_window(detail_winid, false)
    vim.wo[navigator_winid].winfixwidth = true
    vim.api.nvim_win_set_width(navigator_winid, nav_width)

    if not focus and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
    elseif vim.api.nvim_win_is_valid(detail_winid) then
        vim.api.nvim_set_current_win(detail_winid)
    end

    return detail_winid, navigator_winid
end

---@param min_height integer
---@param line_count integer
---@return integer
local function get_target_height(min_height, line_count)
    local height = line_count
    if min_height and min_height > height then
        height = min_height
    end
    local max_height = math.max(1, math.floor((vim.o.lines - 4) / 3))
    return math.max(1, math.min(height, max_height))
end

---@return integer
local function get_layout_width_hint()
    local detail_winid = get_window_for_buffer(detail_bufnr)
    local navigator_winid = get_window_for_buffer(navigator_bufnr)
    if detail_winid and vim.api.nvim_win_is_valid(detail_winid) then
        local width = vim.api.nvim_win_get_width(detail_winid)
        if navigator_winid and vim.api.nvim_win_is_valid(navigator_winid) then
            width = width + vim.api.nvim_win_get_width(navigator_winid)
        end
        return width
    end

    local split_win = find_split_base_window()
    if split_win and vim.api.nvim_win_is_valid(split_win) then
        return vim.api.nvim_win_get_width(split_win)
    end

    return vim.o.columns
end

---@param config_walkthrough NRAIWalkthroughWindow
---@return integer
local function get_target_nav_width(config_walkthrough)
    local preferred_width = math.max(24, config_walkthrough.step_list_width or 52)
    local available_width = get_layout_width_hint()
    local max_fractional_width = math.max(24, math.floor(available_width * 0.65))
    local max_width = math.max(24, math.min(max_fractional_width, available_width - 28))
    return math.min(preferred_width, max_width)
end

---@param bufnr integer
---@param walkthrough NRWalkthrough
---@param step_index integer
---@param width integer
---@return string[]
local function render_navigator(bufnr, walkthrough, step_index, width)
    local lines = build_navigator_lines(walkthrough, step_index, width)
    set_lines(bufnr, lines)

    local heading_lines = {}
    for line_index, line in ipairs(lines) do
        if line == "Overview" or line == string.format("Steps (%d)", #walkthrough.steps) then
            table.insert(heading_lines, line_index)
        end
    end

    if #walkthrough.steps == 0 then
        highlight_navigator(bufnr, lines, heading_lines, {})
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #walkthrough.steps))
    local active_lines = {}
    for line_index, mapped_step_index in pairs(navigator_line_steps) do
        if mapped_step_index == clamped_index then
            table.insert(active_lines, line_index)
        end
    end
    table.sort(active_lines)

    highlight_navigator(bufnr, lines, heading_lines, active_lines)
    return lines
end

---@param bufnr integer
---@param walkthrough NRWalkthrough
---@param step_index integer
---@param width integer
---@return string[]
local function render_detail(bufnr, walkthrough, step_index, width)
    local lines = build_detail_lines(walkthrough, step_index)
    local wrapped = wrap_lines(lines, math.max(20, width - 4))
    set_lines(bufnr, wrapped)
    highlight_detail(bufnr, wrapped)
    return wrapped
end

---@param step_index integer
---@param walkthrough NRWalkthrough
---@param config_walkthrough NRAIWalkthroughWindow
---@return integer
local function render_and_resize(step_index, walkthrough, config_walkthrough)
    local nav_width = get_target_nav_width(config_walkthrough)
    local detail_winid, navigator_winid = ensure_open_with_layout(1, nav_width, config_walkthrough.focus_on_open)
    local detail_width = vim.api.nvim_win_get_width(detail_winid)
    local navigator_width = vim.api.nvim_win_get_width(navigator_winid)
    local navigator_lines = render_navigator(ensure_navigator_buffer(), walkthrough, step_index, navigator_width)
    local detail_lines = render_detail(ensure_detail_buffer(), walkthrough, step_index, detail_width)
    local target_height = get_target_height(config_walkthrough.height, math.max(#navigator_lines, #detail_lines))

    if vim.api.nvim_win_is_valid(detail_winid) then
        vim.api.nvim_win_set_height(detail_winid, target_height)
    end
    if vim.api.nvim_win_is_valid(navigator_winid) then
        vim.api.nvim_win_set_height(navigator_winid, target_height)
        vim.api.nvim_win_set_width(navigator_winid, nav_width)
    end

    return ensure_detail_buffer()
end

---@return nil
local function clear_buffer_highlights(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
end

---@return nil
local function clear_highlights()
    for bufnr, _ in pairs(highlighted_buffers) do
        clear_buffer_highlights(bufnr)
    end
    highlighted_buffers = {}
end

---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@return nil
local function highlight_range(bufnr, start_line, end_line)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local start_idx = math.max(1, math.min(start_line, line_count))
    local end_idx = math.max(1, math.min(end_line, line_count))
    if end_idx < start_idx then
        start_idx, end_idx = end_idx, start_idx
    end

    for line = start_idx, end_idx do
        vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
            line_hl_group = "NRWalkthroughRange",
            priority = 100,
        })
    end
end

---@param path string
---@return boolean
local function is_absolute_path(path)
    return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil
end

---@param root string
---@param file_path string
---@return string
local function join_root(root, file_path)
    if file_path == "" then
        return file_path
    end
    if not root or root == "" then
        return file_path
    end
    if is_absolute_path(file_path) then
        return file_path
    end
    if root:sub(-1) == "/" then
        return root .. file_path
    end
    return root .. "/" .. file_path
end

---@param file_path string
---@return integer|nil
local function find_buffer_by_tail(file_path)
    if file_path == "" then
        return nil
    end
    local escaped = vim.pesc(file_path)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and name:match(escaped .. "$") then
                return bufnr
            end
        end
    end
    return nil
end

---@param root string
---@param file_path string
---@return integer|nil
local function resolve_anchor_buffer(root, file_path)
    if file_path == "" then
        return nil
    end

    local full_path = join_root(root, file_path)
    local bufnr = vim.fn.bufnr(full_path)
    if bufnr ~= -1 then
        vim.fn.bufload(bufnr)
        return bufnr
    end

    local existing = find_buffer_by_tail(file_path)
    if existing then
        vim.fn.bufload(existing)
        return existing
    end

    bufnr = vim.fn.bufadd(full_path)
    vim.fn.bufload(bufnr)
    return bufnr
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return nil
local function apply_step_highlights(walkthrough, step_index)
    clear_highlights()
    define_highlights()

    if #walkthrough.steps == 0 then
        return
    end

    local step = walkthrough.steps[step_index]
    if not step then
        return
    end

    local root = walkthrough.root
    for _, anchor in ipairs(step.anchors or {}) do
        if anchor.file ~= "" then
            local bufnr = resolve_anchor_buffer(root, anchor.file)
            if bufnr then
                highlight_range(bufnr, anchor.start_line, anchor.end_line)
                highlighted_buffers[bufnr] = true
            end
        end
    end
end

---@return boolean
local function focus_non_walkthrough_window()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local filetype = vim.bo[bufnr].filetype
        if
            filetype ~= "neo-reviewer-ai"
            and filetype ~= "neo-reviewer-ai-nav"
            and filetype ~= "neo-reviewer-walkthrough"
            and filetype ~= "neo-reviewer-walkthrough-nav"
            and filetype ~= "neo-reviewer-loading"
        then
            vim.api.nvim_set_current_win(winid)
            return true
        end
    end
    return false
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return nil
local function render_step(walkthrough, step_index)
    local config = require("neo_reviewer.config")
    render_and_resize(step_index, walkthrough, config.values.ai.walkthrough_window)
    apply_step_highlights(walkthrough, step_index)
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@param anchor_index integer|nil
---@return nil
local function jump_to_step(walkthrough, step_index, anchor_index)
    local step = walkthrough.steps[step_index]
    last_step_index = step_index
    last_anchor_index = nil

    if step and step.anchors and #step.anchors > 0 then
        local clamped_anchor_index = math.max(1, math.min(anchor_index or 1, #step.anchors))
        last_anchor_index = clamped_anchor_index
        local anchor = step.anchors[clamped_anchor_index]
        focus_non_walkthrough_window()
        local nav = require("neo_reviewer.ui.nav")
        nav.jump_to(anchor.file, anchor.start_line)
    end

    render_step(walkthrough, step_index)
end

---@param walkthrough NRWalkthrough
---@return integer|nil
local function find_first_anchor_step(walkthrough)
    for index, step in ipairs(walkthrough.steps or {}) do
        if step.anchors and #step.anchors > 0 then
            return index
        end
    end
    return nil
end

---@param path string
---@return string
local function normalize_path(path)
    local normalized = path:gsub("\\", "/")
    return normalized
end

---@param anchor_file string
---@param file_path string
---@return boolean
local function file_matches(anchor_file, file_path)
    local normalized_anchor = normalize_path(anchor_file)
    local normalized_file = normalize_path(file_path)
    return normalized_file == normalized_anchor or normalized_file:match(vim.pesc(normalized_anchor) .. "$") ~= nil
end

---@param walkthrough NRWalkthrough
---@return string|nil
local function get_current_file_path(walkthrough)
    local buffer = require("neo_reviewer.ui.buffer")
    local current_file = buffer.get_current_file_from_buffer()
    if current_file and type(current_file.path) == "string" then
        return normalize_path(current_file.path)
    end

    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname == "" then
        return nil
    end

    local normalized_name = normalize_path(bufname)
    local normalized_root = normalize_path(walkthrough.root or "")
    local root_prefix = normalized_root
    if root_prefix ~= "" and root_prefix:sub(-1) ~= "/" then
        root_prefix = root_prefix .. "/"
    end
    if normalized_root ~= "" and normalized_name == normalized_root then
        if #normalized_name == #normalized_root then
            return ""
        end
        return normalized_name:sub(#normalized_root + 2)
    end
    if root_prefix ~= "" and normalized_name:sub(1, #root_prefix) == root_prefix then
        return normalized_name:sub(#root_prefix + 1)
    end

    return normalized_name
end

---@param walkthrough NRWalkthrough
---@return integer
---@return integer|nil
local function resolve_position(walkthrough)
    local steps = walkthrough.steps or {}
    local current_index = math.max(1, math.min(last_step_index or 1, math.max(#steps, 1)))
    local current_anchor = last_anchor_index

    local file_path = get_current_file_path(walkthrough)
    if file_path then
        local line = vim.api.nvim_win_get_cursor(0)[1]
        for step_index, step in ipairs(steps) do
            for anchor_index, anchor in ipairs(step.anchors or {}) do
                if file_matches(anchor.file, file_path) then
                    local start_line = math.min(anchor.start_line, anchor.end_line)
                    local end_line = math.max(anchor.start_line, anchor.end_line)
                    if line >= start_line and line <= end_line then
                        current_index = step_index
                        current_anchor = anchor_index
                        last_step_index = step_index
                        last_anchor_index = anchor_index
                        return current_index, current_anchor
                    end
                end
            end
        end
    end

    local step = steps[current_index]
    local anchors = step and step.anchors or {}
    if type(current_anchor) == "number" and (current_anchor < 1 or current_anchor > #anchors) then
        current_anchor = nil
    end

    last_step_index = current_index
    last_anchor_index = current_anchor
    return current_index, current_anchor
end

---@param file_path string
---@param line integer
---@param walkthrough NRWalkthrough
---@return integer|nil
---@return integer|nil
local function find_step_for_location(file_path, line, walkthrough)
    for step_index, step in ipairs(walkthrough.steps or {}) do
        for anchor_index, anchor in ipairs(step.anchors or {}) do
            if file_matches(anchor.file, file_path) then
                local start_line = math.min(anchor.start_line, anchor.end_line)
                local end_line = math.max(anchor.start_line, anchor.end_line)
                if line >= start_line and line <= end_line then
                    return step_index, anchor_index
                end
            end
        end
    end
    return nil
end

---@return boolean
local function has_walkthrough_windows()
    return get_window_for_buffer(detail_bufnr) ~= nil or get_window_for_buffer(navigator_bufnr) ~= nil
end

---@return boolean
function M.is_open()
    return has_walkthrough_windows() or get_loading_ui().is_open()
end

---@return nil
function M.show_loading()
    clear_highlights()
    close_windows()

    local config = require("neo_reviewer.config")
    get_loading_ui().show({
        title = "Ask: generating walkthrough",
        message = "Waiting for AI response.",
        focus = config.values.ai.walkthrough_window.focus_on_open,
    })
end

---Open walkthrough in split buffers
---@param opts? NRWalkthroughOpenOpts
---@return nil
function M.open(opts)
    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        vim.notify("No walkthrough available", vim.log.levels.INFO)
        return
    end

    get_loading_ui().close()

    walkthrough.steps = walkthrough.steps or {}

    local step_index = last_step_index or 1
    if opts and opts.jump_to_first then
        step_index = find_first_anchor_step(walkthrough) or 1
    end
    if #walkthrough.steps == 0 then
        step_index = 1
    else
        step_index = math.max(1, math.min(step_index, #walkthrough.steps))
    end

    last_step_index = step_index
    last_anchor_index = nil
    if opts and opts.jump_to_first then
        jump_to_step(walkthrough, step_index)
        return
    end

    render_step(walkthrough, step_index)
end

---@return boolean
function M.close()
    clear_highlights()

    local closed = close_windows()
    if get_loading_ui().close() then
        closed = true
    end

    return closed
end

---@return nil
function M.toggle()
    if M.close() then
        return
    end
    M.open()
end

---@return nil
function M.select_current_step()
    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local step_index = navigator_line_steps[line]
    if not step_index then
        return
    end

    jump_to_step(walkthrough, step_index, 1)
end

---@param wrap boolean
---@return nil
function M.next_step(wrap)
    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        vim.notify("No walkthrough available", vim.log.levels.INFO)
        return
    end

    local steps = walkthrough.steps or {}
    if #steps == 0 then
        vim.notify("No walkthrough steps", vim.log.levels.INFO)
        return
    end

    local current_index, current_anchor = resolve_position(walkthrough)
    local current_step = steps[current_index]
    local anchors = current_step and current_step.anchors or {}

    if #anchors > 0 then
        if not current_anchor then
            jump_to_step(walkthrough, current_index, 1)
            return
        end

        if current_anchor < #anchors then
            jump_to_step(walkthrough, current_index, current_anchor + 1)
            return
        end
    end

    local next_index = current_index + 1
    if next_index > #steps then
        if wrap then
            next_index = 1
            vim.notify("Wrapped to first walkthrough step", vim.log.levels.INFO)
        else
            vim.notify("No more walkthrough steps", vim.log.levels.INFO)
            return
        end
    end

    jump_to_step(walkthrough, next_index, 1)
end

---@param wrap boolean
---@return nil
function M.prev_step(wrap)
    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        vim.notify("No walkthrough available", vim.log.levels.INFO)
        return
    end

    local steps = walkthrough.steps or {}
    if #steps == 0 then
        vim.notify("No walkthrough steps", vim.log.levels.INFO)
        return
    end

    local current_index, current_anchor = resolve_position(walkthrough)
    local current_step = steps[current_index]
    local anchors = current_step and current_step.anchors or {}

    if #anchors > 0 then
        if not current_anchor then
            jump_to_step(walkthrough, current_index, #anchors)
            return
        end

        if current_anchor > 1 then
            jump_to_step(walkthrough, current_index, current_anchor - 1)
            return
        end
    end

    local prev_index = current_index - 1
    if prev_index < 1 then
        if wrap then
            prev_index = #steps
            vim.notify("Wrapped to last walkthrough step", vim.log.levels.INFO)
        else
            vim.notify("No more walkthrough steps", vim.log.levels.INFO)
            return
        end
    end

    local prev_step = steps[prev_index]
    local prev_anchor_count = prev_step and #(prev_step.anchors or {}) or 0
    local target_anchor = prev_anchor_count > 0 and prev_anchor_count or nil
    jump_to_step(walkthrough, prev_index, target_anchor)
end

---Sync walkthrough to a specific location
---@param file_path string
---@param line integer
---@return nil
function M.sync_to_location(file_path, line)
    if not has_walkthrough_windows() then
        return
    end

    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        return
    end

    local step_index, anchor_index = find_step_for_location(file_path, line, walkthrough)
    if not step_index then
        return
    end

    local should_render = last_step_index ~= step_index
    last_step_index = step_index
    last_anchor_index = anchor_index
    if should_render then
        render_step(walkthrough, step_index)
    end
end

return M
