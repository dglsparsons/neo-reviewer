---@class GReviewerNavModule
local M = {}

---@param hunks? GReviewerHunk[]
---@param old_line integer
---@return integer?
local function map_old_line_to_new(hunks, old_line)
    for _, hunk in ipairs(hunks or {}) do
        local deleted_old_lines = hunk.deleted_old_lines or {}
        for i, old_ln in ipairs(deleted_old_lines) do
            if old_ln == old_line then
                local deleted_at = hunk.deleted_at or {}
                if deleted_at[i] then
                    return deleted_at[i]
                end
            end
        end
    end
    return nil
end

---@param comment GReviewerComment
---@param hunks? GReviewerHunk[]
---@return integer?
local function get_comment_display_line(comment, hunks)
    local line = comment.line
    if type(line) ~= "number" then
        return nil
    end
    if comment.side == "LEFT" then
        return map_old_line_to_new(hunks, line) or line
    end
    return line
end

---@param file_path string
---@param hunks? GReviewerHunk[]
---@return integer[]
local function collect_comment_lines(file_path, hunks)
    local state = require("greviewer.state")
    local comments = state.get_comments_for_file(file_path)
    ---@type integer[]
    local lines = {}
    ---@type table<integer, boolean>
    local seen = {}

    for _, comment in ipairs(comments) do
        if type(comment.in_reply_to_id) ~= "number" then
            local display_line = get_comment_display_line(comment, hunks)
            if display_line and not seen[display_line] then
                table.insert(lines, display_line)
                seen[display_line] = true
            end
        end
    end

    table.sort(lines)
    return lines
end

---@param hunk GReviewerHunk
---@return integer?
local function get_hunk_first_change(hunk)
    local first_add = hunk.added_lines and hunk.added_lines[1]
    local first_del = hunk.deleted_at and hunk.deleted_at[1]
    if first_add and first_del then
        return math.min(first_add, first_del)
    end
    return first_add or first_del
end

---@param hunks? GReviewerHunk[]
---@return integer[]
local function collect_hunk_starts(hunks)
    ---@type integer[]
    local starts = {}
    for _, hunk in ipairs(hunks or {}) do
        local first = get_hunk_first_change(hunk)
        if first then
            table.insert(starts, first)
        end
    end
    table.sort(starts)
    return starts
end

---@param review GReviewerReview
---@return integer?
local function get_current_file_index(review)
    local buffer = require("greviewer.ui.buffer")
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
local function jump_to(file_path, line)
    vim.cmd("normal! m'")

    local buffer = require("greviewer.ui.buffer")
    local current_file = buffer.get_current_file_from_buffer()
    local is_same_file = current_file and current_file.path == file_path

    if not is_same_file then
        local current_name = vim.api.nvim_buf_get_name(0)
        is_same_file = current_name:match(vim.pesc(file_path) .. "$")

        if not is_same_file then
            vim.cmd("edit " .. vim.fn.fnameescape(file_path))
        end
    end

    local line_count = vim.api.nvim_buf_line_count(0)
    if line <= line_count then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        vim.cmd("normal! zz")
    end
end

---@param wrap boolean
function M.next_hunk(wrap)
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local hunk_starts = collect_hunk_starts(current_file.hunks)
        for _, ln in ipairs(hunk_starts) do
            if ln > cursor_line then
                jump_to(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[1])
                vim.notify("Wrapped to first change", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more changes", vim.log.levels.INFO)
end

---@param wrap boolean
function M.prev_hunk(wrap)
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local hunk_starts = collect_hunk_starts(current_file.hunks)
        for i = #hunk_starts, 1, -1 do
            if hunk_starts[i] < cursor_line then
                jump_to(current_file.path, hunk_starts[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[#starts])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[#starts])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                jump_to(file.path, starts[#starts])
                vim.notify("Wrapped to last change", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more changes", vim.log.levels.INFO)
end

function M.first_hunk()
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    for _, file in ipairs(review.files) do
        local starts = collect_hunk_starts(file.hunks)
        if #starts > 0 then
            jump_to(file.path, starts[1])
            return
        end
    end
end

function M.last_hunk()
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    for i = #review.files, 1, -1 do
        local file = review.files[i]
        local starts = collect_hunk_starts(file.hunks)
        if #starts > 0 then
            jump_to(file.path, starts[#starts])
            return
        end
    end
end

---@param wrap boolean
function M.next_comment(wrap)
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local comment_lines = collect_comment_lines(current_file.path, current_file.hunks)
        for _, ln in ipairs(comment_lines) do
            if ln > cursor_line then
                jump_to(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[1])
                vim.notify("Wrapped to first comment", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more comments", vim.log.levels.INFO)
end

---@param wrap boolean
function M.prev_comment(wrap)
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_idx = get_current_file_index(review)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    if current_idx then
        local current_file = review.files[current_idx]
        local comment_lines = collect_comment_lines(current_file.path, current_file.hunks)
        for i = #comment_lines, 1, -1 do
            if comment_lines[i] < cursor_line then
                jump_to(current_file.path, comment_lines[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[#lines])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[#lines])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                jump_to(file.path, lines[#lines])
                vim.notify("Wrapped to last comment", vim.log.levels.INFO)
                return
            end
        end
    end

    vim.notify("No more comments", vim.log.levels.INFO)
end

return M
