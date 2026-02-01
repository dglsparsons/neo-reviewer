---@class NRAINavItem
---@field file string File path
---@field change_block_index integer 0-based change block index
---@field line integer Line number to jump to
---@field end_line integer Last line in the change block

---@class NRNavModule
local M = {}

---Build ordered navigation list from AI analysis
---@param review NRReview
---@return NRAINavItem[]|nil
local function build_ai_nav_list(review)
    if not review.ai_analysis then
        return nil
    end

    ---@type NRAINavItem[]
    local nav_list = {}
    ---@type table<string, boolean>
    local seen_by_line = {}

    for _, step in ipairs(review.ai_analysis.steps or {}) do
        for _, block_ref in ipairs(step.change_blocks or {}) do
            local file = review.files_by_path[block_ref.file]
            if file then
                local block = file.change_blocks[block_ref.change_block_index + 1]
                if block then
                    local line_key = block_ref.file .. ":" .. tostring(block.start_line)
                    if not seen_by_line[line_key] then
                        table.insert(nav_list, {
                            file = block_ref.file,
                            change_block_index = block_ref.change_block_index,
                            line = block.start_line,
                            end_line = block.end_line,
                        })
                        seen_by_line[line_key] = true
                    end
                end
            end
        end
    end

    return #nav_list > 0 and nav_list or nil
end

---@param block NRChangeBlock
---@param line integer
---@return boolean
local function is_line_in_change_block(block, line)
    if type(block.start_line) ~= "number" then
        return false
    end

    if block.kind == "delete" then
        return line == block.start_line or line == block.start_line - 1
    end

    local end_line = block.end_line or block.start_line
    return line >= block.start_line and line <= end_line
end

---@param item NRAINavItem
---@return NRAINavAnchor
local function build_ai_nav_anchor(item)
    return {
        file = item.file,
        change_block_index = item.change_block_index,
        line = item.line,
    }
end

---@param nav_list NRAINavItem[]
---@param anchor NRAINavAnchor|nil
---@return integer|nil
local function find_ai_nav_anchor_position(nav_list, anchor)
    if not anchor then
        return nil
    end

    for i, item in ipairs(nav_list) do
        if item.file == anchor.file and item.change_block_index == anchor.change_block_index then
            if anchor.line == nil or anchor.line == item.line then
                return i
            end
        end
    end

    if anchor.line ~= nil then
        for i, item in ipairs(nav_list) do
            if item.file == anchor.file and item.line == anchor.line then
                return i
            end
        end
    end

    return nil
end

---@param change_blocks? NRChangeBlock[]
---@param line integer
---@return integer|nil
local function find_change_block_index_at_line(change_blocks, line)
    for i, block in ipairs(change_blocks or {}) do
        if is_line_in_change_block(block, line) then
            return i - 1
        end
    end
    return nil
end

---@param nav_list NRAINavItem[]
---@param file NRFile
---@param change_block_index integer
---@param cursor_line integer
---@return integer|nil
local function find_ai_position_in_change_block(nav_list, file, change_block_index, cursor_line)
    local candidate = nil
    for i, item in ipairs(nav_list) do
        if item.file == file.path and item.change_block_index == change_block_index then
            local end_line = item.end_line or item.line
            if cursor_line >= item.line and cursor_line <= end_line then
                return i
            end
            if cursor_line > end_line then
                candidate = i
            end
        end
    end

    return candidate
end

---Find current position in AI nav list based on cursor location
---@param review NRReview
---@param nav_list NRAINavItem[]
---@param current_file string|nil
---@param cursor_line integer
---@return integer|nil Current index (1-based), or nil if not found
local function find_ai_nav_position(review, nav_list, current_file, cursor_line)
    if not current_file then
        return nil
    end

    local file = review.files_by_path[current_file]
    if file then
        local change_block_index = find_change_block_index_at_line(file.change_blocks, cursor_line)
        if change_block_index ~= nil then
            local pos = find_ai_position_in_change_block(nav_list, file, change_block_index, cursor_line)
            if pos then
                return pos
            end
        end
    end

    for i, item in ipairs(nav_list) do
        if item.file == current_file and item.line == cursor_line then
            return i
        end
    end

    return nil
end

---@param change_blocks? NRChangeBlock[]
---@param old_line integer
---@return integer?
local function map_old_line_to_new(change_blocks, old_line)
    for _, block in ipairs(change_blocks or {}) do
        for _, mapping in ipairs(block.old_to_new or {}) do
            if mapping.old_line == old_line then
                return mapping.new_line
            end
        end
    end
    return nil
end

---@param comment NRComment
---@param change_blocks? NRChangeBlock[]
---@return integer?
local function get_comment_display_line(comment, change_blocks)
    local line = comment.line
    if type(line) ~= "number" then
        return nil
    end
    if comment.side == "LEFT" then
        return map_old_line_to_new(change_blocks, line) or line
    end
    return line
end

---@param file_path string
---@param change_blocks? NRChangeBlock[]
---@return integer[]
local function collect_comment_lines(file_path, change_blocks)
    local state = require("neo_reviewer.state")
    local comments = state.get_comments_for_file(file_path)
    ---@type integer[]
    local lines = {}
    ---@type table<integer, boolean>
    local seen = {}

    for _, comment in ipairs(comments) do
        if type(comment.in_reply_to_id) ~= "number" then
            local display_line = get_comment_display_line(comment, change_blocks)
            if display_line and not seen[display_line] then
                table.insert(lines, display_line)
                seen[display_line] = true
            end
        end
    end

    table.sort(lines)
    return lines
end

---@param change_blocks? NRChangeBlock[]
---@return integer[]
local function collect_change_starts(change_blocks)
    ---@type integer[]
    local starts = {}
    ---@type table<integer, boolean>
    local seen = {}

    for _, block in ipairs(change_blocks or {}) do
        if not seen[block.start_line] then
            table.insert(starts, block.start_line)
            seen[block.start_line] = true
        end
    end

    table.sort(starts)
    return starts
end

---@param review NRReview
---@return integer?
local function get_current_file_index(review)
    local buffer = require("neo_reviewer.ui.buffer")
    local current_file = buffer.get_current_file_from_buffer()
    if current_file then
        for i, file in ipairs(review.files) do
            if file.path == current_file.path then
                return i
            end
        end
    end
    return nil
end

---@param file_path string
---@param line integer
function M.jump_to(file_path, line)
    vim.cmd("normal! m'")

    local buffer = require("neo_reviewer.ui.buffer")
    local current_file = buffer.get_current_file_from_buffer()
    local is_same_file = current_file and current_file.path == file_path

    if not is_same_file then
        local current_name = vim.api.nvim_buf_get_name(0)
        is_same_file = current_name:match(vim.pesc(file_path) .. "$")

        if not is_same_file then
            local state = require("neo_reviewer.state")
            local git_root = state.get_git_root()
            local full_path = git_root and (git_root .. "/" .. file_path) or file_path
            vim.cmd("edit " .. vim.fn.fnameescape(full_path))
        end
    end

    local line_count = vim.api.nvim_buf_line_count(0)
    local target_line = math.max(1, math.min(line, line_count))
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    vim.cmd("normal! zz")
end

---@param wrap boolean
function M.next_change(wrap)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local ai_ui = require("neo_reviewer.ui.ai")
    local ai_nav_list = build_ai_nav_list(review)

    if ai_nav_list then
        local buffer = require("neo_reviewer.ui.buffer")
        local current_file = buffer.get_current_file_from_buffer()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
        local current_path = current_file and current_file.path

        local current_pos = find_ai_nav_position(review, ai_nav_list, current_path, cursor_line)
        if current_pos then
            state.set_ai_nav_anchor(build_ai_nav_anchor(ai_nav_list[current_pos]))
        else
            local anchor_pos = find_ai_nav_anchor_position(ai_nav_list, state.get_ai_nav_anchor())
            if anchor_pos then
                current_pos = anchor_pos
            end
        end

        if current_pos and current_pos < #ai_nav_list then
            local next_item = ai_nav_list[current_pos + 1]
            M.jump_to(next_item.file, next_item.line)
            state.set_ai_nav_anchor(build_ai_nav_anchor(next_item))
            ai_ui.sync_to_location(next_item.file, next_item.line)
            return
        elseif not current_pos then
            for _, item in ipairs(ai_nav_list) do
                if not current_path or item.file ~= current_path or item.line > cursor_line then
                    M.jump_to(item.file, item.line)
                    state.set_ai_nav_anchor(build_ai_nav_anchor(item))
                    ai_ui.sync_to_location(item.file, item.line)
                    return
                end
            end
        end

        if wrap and #ai_nav_list > 0 then
            M.jump_to(ai_nav_list[1].file, ai_nav_list[1].line)
            vim.notify("Wrapped to first change (AI order)", vim.log.levels.INFO)
            state.set_ai_nav_anchor(build_ai_nav_anchor(ai_nav_list[1]))
            ai_ui.sync_to_location(ai_nav_list[1].file, ai_nav_list[1].line)
            return
        end

        vim.notify("No more changes", vim.log.levels.INFO)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local change_starts = collect_change_starts(current_file.change_blocks)
        for _, ln in ipairs(change_starts) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                ai_ui.sync_to_location(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                vim.notify("Wrapped to first change", vim.log.levels.INFO)
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    end

    vim.notify("No more changes", vim.log.levels.INFO)
end

---@param wrap boolean
function M.prev_change(wrap)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local ai_ui = require("neo_reviewer.ui.ai")
    local ai_nav_list = build_ai_nav_list(review)

    if ai_nav_list then
        local buffer = require("neo_reviewer.ui.buffer")
        local current_file = buffer.get_current_file_from_buffer()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
        local current_path = current_file and current_file.path

        local current_pos = find_ai_nav_position(review, ai_nav_list, current_path, cursor_line)
        if current_pos then
            state.set_ai_nav_anchor(build_ai_nav_anchor(ai_nav_list[current_pos]))
        else
            local anchor_pos = find_ai_nav_anchor_position(ai_nav_list, state.get_ai_nav_anchor())
            if anchor_pos then
                current_pos = anchor_pos
            end
        end

        if current_pos and current_pos > 1 then
            local prev_item = ai_nav_list[current_pos - 1]
            M.jump_to(prev_item.file, prev_item.line)
            state.set_ai_nav_anchor(build_ai_nav_anchor(prev_item))
            ai_ui.sync_to_location(prev_item.file, prev_item.line)
            return
        elseif not current_pos then
            for i = #ai_nav_list, 1, -1 do
                local item = ai_nav_list[i]
                if not current_path or item.file ~= current_path or item.line < cursor_line then
                    M.jump_to(item.file, item.line)
                    state.set_ai_nav_anchor(build_ai_nav_anchor(item))
                    ai_ui.sync_to_location(item.file, item.line)
                    return
                end
            end
        end

        if wrap and #ai_nav_list > 0 then
            local last = ai_nav_list[#ai_nav_list]
            M.jump_to(last.file, last.line)
            vim.notify("Wrapped to last change (AI order)", vim.log.levels.INFO)
            state.set_ai_nav_anchor(build_ai_nav_anchor(last))
            ai_ui.sync_to_location(last.file, last.line)
            return
        end

        vim.notify("No more changes", vim.log.levels.INFO)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local change_starts = collect_change_starts(current_file.change_blocks)
        for i = #change_starts, 1, -1 do
            if change_starts[i] < cursor_line then
                M.jump_to(current_file.path, change_starts[i])
                ai_ui.sync_to_location(current_file.path, change_starts[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[#starts])
                ai_ui.sync_to_location(file.path, starts[#starts])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[#starts])
                ai_ui.sync_to_location(file.path, starts[#starts])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_change_starts(file.change_blocks)
            if #starts > 0 then
                M.jump_to(file.path, starts[#starts])
                vim.notify("Wrapped to last change", vim.log.levels.INFO)
                ai_ui.sync_to_location(file.path, starts[#starts])
                return
            end
        end
    end

    vim.notify("No more changes", vim.log.levels.INFO)
end

function M.first_change()
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local ai_nav_list = build_ai_nav_list(review)
    if ai_nav_list and #ai_nav_list > 0 then
        local first = ai_nav_list[1]
        M.jump_to(first.file, first.line)
        state.set_ai_nav_anchor(build_ai_nav_anchor(first))
        return
    end

    for _, file in ipairs(review.files) do
        local starts = collect_change_starts(file.change_blocks)
        if #starts > 0 then
            M.jump_to(file.path, starts[1])
            return
        end
    end
end

function M.last_change()
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local ai_nav_list = build_ai_nav_list(review)
    if ai_nav_list and #ai_nav_list > 0 then
        local last = ai_nav_list[#ai_nav_list]
        M.jump_to(last.file, last.line)
        state.set_ai_nav_anchor(build_ai_nav_anchor(last))
        return
    end

    for i = #review.files, 1, -1 do
        local file = review.files[i]
        local starts = collect_change_starts(file.change_blocks)
        if #starts > 0 then
            M.jump_to(file.path, starts[#starts])
            return
        end
    end
end

---@param wrap boolean
function M.next_comment(wrap)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local comment_lines = collect_comment_lines(current_file.path, current_file.change_blocks)
        for _, ln in ipairs(comment_lines) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                vim.notify("Wrapped to first comment", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more comments", vim.log.levels.INFO)
end

---@param wrap boolean
function M.prev_comment(wrap)
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local comment_lines = collect_comment_lines(current_file.path, current_file.change_blocks)
        for i = #comment_lines, 1, -1 do
            if comment_lines[i] < cursor_line then
                M.jump_to(current_file.path, comment_lines[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.change_blocks)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                vim.notify("Wrapped to last comment", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more comments", vim.log.levels.INFO)
end

return M
