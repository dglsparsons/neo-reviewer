---@class NRAIUIModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_ai")

local walkthrough_bufnr = nil
local last_step_index = nil

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

---@param analysis NRAIAnalysis
---@param step_index integer
---@return string[]
local function build_walkthrough_lines(analysis, step_index)
    ---@type string[]
    local lines = {}

    table.insert(lines, "Overview:")
    for _, line in ipairs(split_lines(analysis.overview)) do
        table.insert(lines, line)
    end

    if #analysis.steps == 0 then
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps provided.")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #analysis.steps))
    local step = analysis.steps[clamped_index]

    table.insert(lines, "")
    table.insert(lines, string.format("Step %d/%d: %s", clamped_index, #analysis.steps, step.title))
    table.insert(lines, "")
    for _, line in ipairs(split_lines(step.explanation)) do
        table.insert(lines, line)
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
                local file = review.files_by_path[file_path]
                if file then
                    local block = file.change_blocks[block_ref.change_block_index + 1]
                    if block then
                        local start_line, end_line = get_change_block_range(review, block_ref)
                        if start_line and end_line and line >= start_line and line <= end_line then
                            return step_index
                        end
                    end
                end
            end
        end
    end

    return nil
end

---@param bufnr integer
---@param lines string[]
local function set_lines(bufnr, lines)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

---@param bufnr integer
---@param analysis NRAIAnalysis
---@param step_index integer
---@return string[]
local function render_walkthrough(bufnr, analysis, step_index)
    local winid = vim.fn.bufwinid(bufnr)
    local width = vim.o.columns
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        width = vim.api.nvim_win_get_width(winid)
    end
    width = math.max(20, width - 4)
    local lines = build_walkthrough_lines(analysis, step_index)
    local wrapped = wrap_lines(lines, width)
    set_lines(bufnr, wrapped)
    return wrapped
end

---@return integer
local function ensure_walkthrough_buffer()
    if walkthrough_bufnr and vim.api.nvim_buf_is_valid(walkthrough_bufnr) then
        return walkthrough_bufnr
    end

    walkthrough_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[walkthrough_bufnr].buftype = "nofile"
    vim.bo[walkthrough_bufnr].bufhidden = "hide"
    vim.bo[walkthrough_bufnr].swapfile = false
    vim.bo[walkthrough_bufnr].modifiable = false
    vim.bo[walkthrough_bufnr].filetype = "neo-reviewer-ai"

    return walkthrough_bufnr
end

---@param height integer
---@param focus boolean
---@return integer
local function open_walkthrough_split(height, focus)
    local bufnr = ensure_walkthrough_buffer()
    local winid = vim.fn.bufwinid(bufnr)
    local current_win = vim.api.nvim_get_current_win()
    if winid == -1 then
        vim.cmd("botright " .. tostring(height) .. "split")
        vim.api.nvim_set_current_buf(bufnr)
        winid = vim.api.nvim_get_current_win()
    end

    if not focus then
        if vim.api.nvim_win_is_valid(current_win) then
            vim.api.nvim_set_current_win(current_win)
        end
    end

    return winid
end

---Apply AI annotations as virtual text to a buffer (no-op; walkthrough uses a split)
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

---@return integer
local function get_target_height(min_height, line_count)
    local height = line_count
    if min_height and min_height > height then
        height = min_height
    end
    return math.max(1, height)
end

---@return integer, integer
local function ensure_open_with_height(height, focus)
    local winid = open_walkthrough_split(height, focus)
    return winid, ensure_walkthrough_buffer()
end

---@param step_index integer
---@param analysis NRAIAnalysis
---@param config_walkthrough NRAIWalkthroughWindow
---@return integer
local function render_and_resize(step_index, analysis, config_walkthrough)
    local winid, bufnr = ensure_open_with_height(1, config_walkthrough.focus_on_open)
    local wrapped = render_walkthrough(bufnr, analysis, step_index)
    local target_height = get_target_height(config_walkthrough.height, #wrapped)
    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_set_height(winid, target_height)
    end
    return bufnr
end

---Open walkthrough in a split buffer
function M.open()
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    local analysis = state.get_ai_analysis()
    if not review or not analysis then
        vim.notify("No AI analysis available", vim.log.levels.INFO)
        return
    end

    analysis.steps = analysis.steps or {}

    local config = require("neo_reviewer.config")
    local walkthrough = config.values.ai.walkthrough_window
    local step_index = last_step_index or 1
    last_step_index = step_index
    render_and_resize(step_index, analysis, walkthrough)
end

---@return boolean
function M.is_open()
    if not walkthrough_bufnr or not vim.api.nvim_buf_is_valid(walkthrough_bufnr) then
        return false
    end
    return vim.fn.bufwinid(walkthrough_bufnr) ~= -1
end

---@return boolean
function M.close()
    local bufnr = walkthrough_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return false
    end

    vim.api.nvim_win_close(winid, true)
    return true
end

---Toggle walkthrough open/close
function M.show_details()
    if M.close() then
        return
    end

    M.open()
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
    local analysis = review.ai_analysis
    if not analysis then
        return
    end

    local bufnr = walkthrough_bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return
    end

    local step_index = find_step_for_location(review, file_path, line)
    if not step_index then
        return
    end

    if last_step_index ~= step_index then
        last_step_index = step_index
        local config = require("neo_reviewer.config")
        render_and_resize(step_index, analysis, config.values.ai.walkthrough_window)
    end
end

return M
