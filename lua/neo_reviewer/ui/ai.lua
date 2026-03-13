---@class NRAIUIModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_ai")

local detail_bufnr = nil
local navigator_bufnr = nil
local last_step_index = nil

---@type table<integer, integer>
local navigator_line_steps = {}

---@class NRAIOpenOpts
---@field preserve_layout? boolean Preserve existing split sizes when re-rendering an open walkthrough

---@return nil
local function define_highlights()
    vim.api.nvim_set_hl(0, "NRAIHeading", { bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIActiveStep", { bg = "#28343d", default = true })
    vim.api.nvim_set_hl(0, "NRAIMuted", { link = "Comment", default = true })
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
    return text .. "..."
end

---@param review NRReview
---@param step NRAIWalkthroughStep
---@return string[]
local function collect_step_files(review, step)
    ---@type string[]
    local files = {}
    ---@type table<string, boolean>
    local seen = {}

    for _, block_ref in ipairs(step.change_blocks or {}) do
        local file = review.files_by_path[block_ref.file]
        if file and not seen[file.path] then
            table.insert(files, file.path)
            seen[file.path] = true
        end
    end

    return files
end

---@param analysis NRAIAnalysis
---@param step_index integer
---@param width integer
---@return string[]
local function build_navigator_lines(analysis, step_index, width)
    local available_width = math.max(16, width - 2)

    ---@type string[]
    local lines = {}
    navigator_line_steps = {}

    table.insert(lines, "Overview")
    local overview_lines = wrap_lines(summarize_overview(analysis.overview, 2), available_width)
    for _, line in ipairs(overview_lines) do
        table.insert(lines, line)
    end

    if #analysis.steps == 0 then
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #analysis.steps))

    table.insert(lines, "")
    table.insert(lines, string.format("Steps (%d)", #analysis.steps))

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

    for current_index, step in ipairs(analysis.steps) do
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

---@param review NRReview
---@param analysis NRAIAnalysis
---@param step_index integer
---@return string[]
local function build_detail_lines(review, analysis, step_index)
    ---@type string[]
    local lines = {}

    if #analysis.steps == 0 then
        table.insert(lines, "Overview")
        for _, line in ipairs(split_lines(analysis.overview)) do
            table.insert(lines, line)
        end
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps provided.")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #analysis.steps))
    local step = analysis.steps[clamped_index]
    local files = collect_step_files(review, step)
    local change_block_count = #(step.change_blocks or {})

    table.insert(lines, string.format("Step %d/%d", clamped_index, #analysis.steps))
    table.insert(lines, step.title)
    table.insert(
        lines,
        string.format(
            "%d change block%s across %d file%s",
            change_block_count,
            change_block_count == 1 and "" or "s",
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

---@param review NRReview
---@param block_ref NRAIWalkthroughChangeRef
---@return integer|nil
---@return integer|nil
local function get_change_block_range(review, block_ref)
    local file = review.files_by_path[block_ref.file]
    if not file then
        return nil, nil
    end

    local block = file.change_blocks[block_ref.change_block_index + 1]
    if not block or type(block.start_line) ~= "number" then
        return nil, nil
    end

    local start_line = block.start_line
    local end_line = block.end_line or start_line
    local buffer = require("neo_reviewer.ui.buffer")
    local current_start, current_end =
        buffer.get_change_block_range_for_file(file, block_ref.change_block_index, start_line, end_line)

    return current_start or start_line, current_end or end_line
end

---@param review NRReview
---@param step NRAIWalkthroughStep
---@return string|nil
---@return integer|nil
---@return integer|nil
---@return integer|nil
local function get_step_anchor(review, step)
    for _, block_ref in ipairs(step.change_blocks or {}) do
        local start_line, end_line = get_change_block_range(review, block_ref)
        if start_line and end_line then
            return block_ref.file, start_line, end_line, block_ref.change_block_index
        end
    end

    return nil, nil, nil, nil
end

---@param review NRReview
---@param file_path string
---@param line integer
---@return integer|nil
local function find_step_for_location(review, file_path, line)
    if not review.ai_analysis then
        return nil
    end

    for step_index, step in ipairs(review.ai_analysis.steps or {}) do
        for _, block_ref in ipairs(step.change_blocks or {}) do
            if block_ref.file == file_path then
                local start_line, end_line = get_change_block_range(review, block_ref)
                if start_line and end_line and line >= start_line and line <= end_line then
                    return step_index
                end
            end
        end
    end

    return nil
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
            highlight_line(bufnr, line_index, "NRAIHeading")
        end
    end

    for _, line_index in ipairs(active_lines) do
        if lines[line_index] then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line_index - 1, 0, {
                line_hl_group = "NRAIActiveStep",
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
        if line == "Details" or line == "Files In This Step" then
            highlight_line(bufnr, line_index, "NRAIHeading")
        elseif line:match("^Step %d+/%d+$") then
            highlight_line(bufnr, line_index, "NRAIMuted")
        end
    end

    if lines[1] and lines[1]:match("^Step %d+/%d+$") and lines[2] then
        highlight_line(bufnr, 2, "NRAIHeading")
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
    vim.bo[detail_bufnr].filetype = "neo-reviewer-ai"

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
    vim.bo[navigator_bufnr].filetype = "neo-reviewer-ai-nav"

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
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

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
        error("failed to open AI walkthrough windows")
    end

    configure_window(navigator_winid, false)
    configure_window(detail_winid, false)
    vim.wo[detail_winid].winfixwidth = false
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
    -- Keep the overview readable by default, but still leave the detail pane enough width to be useful.
    local max_fractional_width = math.max(24, math.floor(available_width * 0.65))
    local max_width = math.max(24, math.min(max_fractional_width, available_width - 28))
    return math.min(preferred_width, max_width)
end

---@param bufnr integer
---@param analysis NRAIAnalysis
---@param step_index integer
---@param width integer
---@return string[]
local function render_navigator(bufnr, analysis, step_index, width)
    local lines = build_navigator_lines(analysis, step_index, width)
    set_lines(bufnr, lines)
    local heading_lines = {}
    for line_index, line in ipairs(lines) do
        if line == "Overview" or line == string.format("Steps (%d)", #analysis.steps) then
            table.insert(heading_lines, line_index)
        end
    end
    if #analysis.steps == 0 then
        highlight_navigator(bufnr, lines, heading_lines, {})
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #analysis.steps))
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
---@param review NRReview
---@param analysis NRAIAnalysis
---@param step_index integer
---@param width integer
---@return string[]
local function render_detail(bufnr, review, analysis, step_index, width)
    local lines = build_detail_lines(review, analysis, step_index)
    local wrapped = wrap_lines(lines, math.max(20, width - 4))
    set_lines(bufnr, wrapped)
    highlight_detail(bufnr, wrapped)
    return wrapped
end

---@param step_index integer
---@param review NRReview
---@param analysis NRAIAnalysis
---@param config_walkthrough NRAIWalkthroughWindow
---@param opts? NRAIOpenOpts
---@return integer
local function render_and_resize(step_index, review, analysis, config_walkthrough, opts)
    opts = opts or {}
    local existing_detail_winid = get_window_for_buffer(detail_bufnr)
    local existing_navigator_winid = get_window_for_buffer(navigator_bufnr)
    local preserve_layout = opts.preserve_layout
        and existing_detail_winid
        and vim.api.nvim_win_is_valid(existing_detail_winid)
        and existing_navigator_winid
        and vim.api.nvim_win_is_valid(existing_navigator_winid)

    local nav_width = get_target_nav_width(config_walkthrough)
    if preserve_layout then
        ---@cast existing_navigator_winid integer
        nav_width = vim.api.nvim_win_get_width(existing_navigator_winid)
    end
    local detail_winid, navigator_winid = ensure_open_with_layout(1, nav_width, config_walkthrough.focus_on_open)
    local detail_width = vim.api.nvim_win_get_width(detail_winid)
    local navigator_width = vim.api.nvim_win_get_width(navigator_winid)
    local navigator_lines = render_navigator(ensure_navigator_buffer(), analysis, step_index, navigator_width)
    local detail_lines = render_detail(ensure_detail_buffer(), review, analysis, step_index, detail_width)

    if preserve_layout then
        return ensure_detail_buffer()
    end

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

---@return boolean
local function focus_non_ai_window()
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

---@param review NRReview
---@param analysis NRAIAnalysis
---@param step_index integer
---@param jump_to_code boolean
---@return nil
local function select_step(review, analysis, step_index, jump_to_code)
    if #analysis.steps == 0 then
        return
    end

    local clamped_index = math.max(1, math.min(step_index, #analysis.steps))
    last_step_index = clamped_index

    local config = require("neo_reviewer.config")
    render_and_resize(clamped_index, review, analysis, config.values.ai.walkthrough_window)

    if not jump_to_code then
        return
    end

    local file_path, start_line, _, change_block_index = get_step_anchor(review, analysis.steps[clamped_index])
    if not file_path or not start_line or change_block_index == nil then
        return
    end

    focus_non_ai_window()
    local nav = require("neo_reviewer.ui.nav")
    local state = require("neo_reviewer.state")
    nav.jump_to(file_path, start_line)
    state.set_ai_nav_anchor({
        file = file_path,
        change_block_index = change_block_index,
        line = start_line,
    })
end

---Apply AI annotations as virtual text to a buffer (no-op; walkthrough uses split panes)
---@param bufnr integer
---@param _ NRFile
function M.apply(bufnr, _)
    M.clear(bufnr)
end

---Clear AI annotations from a buffer
---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---Open walkthrough in split buffers
---@param opts? NRAIOpenOpts
function M.open(opts)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    local analysis = state.get_ai_analysis()
    if not review or not analysis then
        vim.notify("No AI analysis available", vim.log.levels.INFO)
        return
    end

    analysis.steps = analysis.steps or {}
    local step_index = last_step_index or 1
    if #analysis.steps > 0 then
        step_index = math.max(1, math.min(step_index, #analysis.steps))
    end
    last_step_index = step_index

    local config = require("neo_reviewer.config")
    render_and_resize(step_index, review, analysis, config.values.ai.walkthrough_window, opts)
end

---@return boolean
function M.is_open()
    return get_window_for_buffer(detail_bufnr) ~= nil or get_window_for_buffer(navigator_bufnr) ~= nil
end

---@return boolean
function M.close()
    return close_windows()
end

---Toggle walkthrough open/close
function M.show_details()
    if M.close() then
        return
    end

    M.open()
end

---Select the step under the cursor in the navigator pane.
function M.select_current_step()
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    local analysis = state.get_ai_analysis()
    if not review or not analysis then
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local step_index = navigator_line_steps[line]
    if not step_index then
        return
    end

    select_step(review, analysis, step_index, true)
end

---Sync walkthrough to a specific location
---@param file_path string
---@param line integer
function M.sync_to_location(file_path, line)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review or not review.ai_analysis then
        return
    end

    if not M.is_open() then
        return
    end

    local step_index = find_step_for_location(review, file_path, line)
    if not step_index or last_step_index == step_index then
        return
    end

    last_step_index = step_index
    local config = require("neo_reviewer.config")
    render_and_resize(step_index, review, review.ai_analysis, config.values.ai.walkthrough_window)
end

return M
