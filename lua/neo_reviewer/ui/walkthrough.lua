---@class NRWalkthroughUIModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_walkthrough")

local walkthrough_bufnr = nil
local last_step_index = nil
---@type table<integer, boolean>
local highlighted_buffers = {}

---@return nil
local function define_highlights()
    vim.api.nvim_set_hl(0, "NRWalkthroughRange", { link = "Visual", default = true })
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

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return string[]
local function build_walkthrough_lines(walkthrough, step_index)
    ---@type string[]
    local lines = {}

    table.insert(lines, "Overview:")
    for _, line in ipairs(split_lines(walkthrough.overview)) do
        table.insert(lines, line)
    end

    if #walkthrough.steps == 0 then
        table.insert(lines, "")
        table.insert(lines, "No walkthrough steps provided.")
        return lines
    end

    local clamped_index = math.max(1, math.min(step_index, #walkthrough.steps))
    local step = walkthrough.steps[clamped_index]

    table.insert(lines, "")
    table.insert(lines, string.format("Step %d/%d: %s", clamped_index, #walkthrough.steps, step.title))
    table.insert(lines, "")
    for _, line in ipairs(split_lines(step.explanation)) do
        table.insert(lines, line)
    end

    if #step.anchors > 0 then
        table.insert(lines, "")
        table.insert(lines, "Anchors:")
        for _, anchor in ipairs(step.anchors) do
            table.insert(lines, string.format("- %s:%d-%d", anchor.file, anchor.start_line, anchor.end_line))
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
---@param walkthrough NRWalkthrough
---@param step_index integer
---@return string[]
local function render_walkthrough(bufnr, walkthrough, step_index)
    local winid = vim.fn.bufwinid(bufnr)
    local width = vim.o.columns
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
        width = vim.api.nvim_win_get_width(winid)
    end
    width = math.max(20, width - 4)
    local lines = build_walkthrough_lines(walkthrough, step_index)
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
    vim.bo[walkthrough_bufnr].filetype = "neo-reviewer-walkthrough"

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

---@param min_height integer
---@param line_count integer
---@return integer
local function get_target_height(min_height, line_count)
    local height = line_count
    if min_height and min_height > height then
        height = min_height
    end
    return math.max(1, height)
end

---@param height integer
---@param focus boolean
---@return integer, integer
local function ensure_open_with_height(height, focus)
    local winid = open_walkthrough_split(height, focus)
    return winid, ensure_walkthrough_buffer()
end

---@param bufnr integer
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
            hl_group = "NRWalkthroughRange",
            hl_eol = true,
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
        if type(anchor.file) == "string" and anchor.file ~= "" then
            local full_path = join_root(root, anchor.file)
            local bufnr = vim.fn.bufadd(full_path)
            vim.fn.bufload(bufnr)
            highlight_range(bufnr, anchor.start_line, anchor.end_line)
            highlighted_buffers[bufnr] = true
        end
    end
end

---@param step_index integer
---@param walkthrough NRWalkthrough
---@param config_walkthrough NRAIWalkthroughWindow
---@return integer
local function render_and_resize(step_index, walkthrough, config_walkthrough)
    local winid, bufnr = ensure_open_with_height(1, config_walkthrough.focus_on_open)
    local wrapped = render_walkthrough(bufnr, walkthrough, step_index)
    local target_height = get_target_height(config_walkthrough.height, #wrapped)
    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_set_height(winid, target_height)
    end
    return bufnr
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return nil
local function render_step(walkthrough, step_index)
    local config = require("neo_reviewer.config")
    render_and_resize(step_index, walkthrough, config.values.ai.walkthrough_window)
    apply_step_highlights(walkthrough, step_index)
end

---@return boolean
function M.is_open()
    if not walkthrough_bufnr or not vim.api.nvim_buf_is_valid(walkthrough_bufnr) then
        return false
    end
    return vim.fn.bufwinid(walkthrough_bufnr) ~= -1
end

---Open walkthrough in a split buffer
---@return nil
function M.open()
    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        vim.notify("No walkthrough available", vim.log.levels.INFO)
        return
    end

    walkthrough.steps = walkthrough.steps or {}

    local step_index = last_step_index or 1
    if #walkthrough.steps == 0 then
        step_index = 1
    else
        step_index = math.max(1, math.min(step_index, #walkthrough.steps))
    end

    last_step_index = step_index
    render_step(walkthrough, step_index)
end

---@return boolean
function M.close()
    clear_highlights()

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
---@return nil
function M.toggle()
    if M.close() then
        return
    end
    M.open()
end

---@param walkthrough NRWalkthrough
---@param step_index integer
---@return nil
local function jump_to_step(walkthrough, step_index)
    local step = walkthrough.steps[step_index]
    last_step_index = step_index

    if step and step.anchors and step.anchors[1] then
        local nav = require("neo_reviewer.ui.nav")
        nav.jump_to(step.anchors[1].file, step.anchors[1].start_line)
    end

    render_step(walkthrough, step_index)
end

---@param file_path string
---@param line integer
---@return integer|nil
local function find_step_for_location(file_path, line, walkthrough)
    for step_index, step in ipairs(walkthrough.steps or {}) do
        for _, anchor in ipairs(step.anchors or {}) do
            if anchor.file == file_path then
                local start_line = math.min(anchor.start_line, anchor.end_line)
                local end_line = math.max(anchor.start_line, anchor.end_line)
                if line >= start_line and line <= end_line then
                    return step_index
                end
            end
        end
    end
    return nil
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

    local current_index = last_step_index or 1
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

    jump_to_step(walkthrough, next_index)
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

    local current_index = last_step_index or 1
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

    jump_to_step(walkthrough, prev_index)
end

---Sync walkthrough to a specific location
---@param file_path string
---@param line integer
---@return nil
function M.sync_to_location(file_path, line)
    if not M.is_open() then
        return
    end

    local state = require("neo_reviewer.state")
    local walkthrough = state.get_walkthrough()
    if not walkthrough then
        return
    end

    local step_index = find_step_for_location(file_path, line, walkthrough)
    if not step_index then
        return
    end

    if last_step_index ~= step_index then
        last_step_index = step_index
        render_step(walkthrough, step_index)
    end
end

return M
