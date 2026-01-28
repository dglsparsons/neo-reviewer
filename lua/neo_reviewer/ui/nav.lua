---@class NRAINavItem
---@field file string File path
---@field hunk_index integer 0-based hunk index
---@field line integer Line number to jump to

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
    local seen_by_index = {}
    ---@type table<string, boolean>
    local seen_by_line = {}

    for _, step in ipairs(review.ai_analysis.steps or {}) do
        for _, hunk_ref in ipairs(step.hunks or {}) do
            local index_key = hunk_ref.file .. ":" .. tostring(hunk_ref.hunk_index)
            if not seen_by_index[index_key] then
                local file = review.files_by_path[hunk_ref.file]
                if file then
                    local hunk = file.hunks[hunk_ref.hunk_index + 1]
                    if hunk then
                        local first_add = hunk.added_lines and hunk.added_lines[1]
                        local first_del = hunk.deleted_at and hunk.deleted_at[1]
                        local line = nil
                        if first_add and first_del then
                            line = math.min(first_add, first_del)
                        else
                            line = first_add or first_del
                        end

                        if line then
                            local line_key = hunk_ref.file .. ":" .. tostring(line)
                            if not seen_by_line[line_key] then
                                table.insert(nav_list, {
                                    file = hunk_ref.file,
                                    hunk_index = hunk_ref.hunk_index,
                                    line = line,
                                })
                                seen_by_line[line_key] = true
                            end
                        end
                    end
                end

                -- Avoid bouncing to the same hunk/line when AI order repeats entries.
                seen_by_index[index_key] = true
            end
        end
    end

    return #nav_list > 0 and nav_list or nil
end

---@param hunk NRHunk
---@param line integer
---@return boolean
local function is_line_in_hunk(hunk, line)
    if type(hunk.start) ~= "number" then
        return false
    end

    if hunk.hunk_type == "delete" then
        return line == hunk.start or line == hunk.start - 1
    end

    local count = hunk.count
    if type(count) ~= "number" then
        count = 1
    end

    local hunk_end = hunk.start + math.max(count - 1, 0)
    return line >= hunk.start and line <= hunk_end
end

---@param item NRAINavItem
---@return NRAINavAnchor
local function build_ai_nav_anchor(item)
    return {
        file = item.file,
        hunk_index = item.hunk_index,
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
        if item.file == anchor.file and item.hunk_index == anchor.hunk_index then
            return i
        end
    end

    return nil
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
        for i, item in ipairs(nav_list) do
            if item.file == current_file then
                local hunk = file.hunks[item.hunk_index + 1]
                if hunk and is_line_in_hunk(hunk, cursor_line) then
                    return i
                end
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

---@param hunks? NRHunk[]
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

---@param comment NRComment
---@param hunks? NRHunk[]
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
---@param hunks? NRHunk[]
---@return integer[]
local function collect_comment_lines(file_path, hunks)
    local state = require("neo_reviewer.state")
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

---@param hunk NRHunk
---@return integer?
local function get_hunk_first_change(hunk)
    local first_add = hunk.added_lines and hunk.added_lines[1]
    local first_del = hunk.deleted_at and hunk.deleted_at[1]
    if first_add and first_del then
        return math.min(first_add, first_del)
    end
    return first_add or first_del
end

---@param hunks? NRHunk[]
---@return integer[]
local function collect_hunk_starts(hunks)
    ---@type integer[]
    local starts = {}
    ---@type table<integer, boolean>
    local seen = {}
    for _, hunk in ipairs(hunks or {}) do
        local first = get_hunk_first_change(hunk)
        if first and not seen[first] then
            table.insert(starts, first)
            seen[first] = true
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
function M.next_hunk(wrap)
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
            for i, item in ipairs(ai_nav_list) do
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
        local hunk_starts = collect_hunk_starts(current_file.hunks)
        for _, ln in ipairs(hunk_starts) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                ai_ui.sync_to_location(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local starts = collect_hunk_starts(file.hunks)
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
function M.prev_hunk(wrap)
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
        local hunk_starts = collect_hunk_starts(current_file.hunks)
        for i = #hunk_starts, 1, -1 do
            if hunk_starts[i] < cursor_line then
                M.jump_to(current_file.path, hunk_starts[i])
                ai_ui.sync_to_location(current_file.path, hunk_starts[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
            if #starts > 0 then
                M.jump_to(file.path, starts[#starts])
                ai_ui.sync_to_location(file.path, starts[#starts])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_hunk_starts(file.hunks)
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
            local starts = collect_hunk_starts(file.hunks)
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

function M.first_hunk()
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
        local starts = collect_hunk_starts(file.hunks)
        if #starts > 0 then
            M.jump_to(file.path, starts[1])
            return
        end
    end
end

function M.last_hunk()
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
        local starts = collect_hunk_starts(file.hunks)
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
        local comment_lines = collect_comment_lines(current_file.path, current_file.hunks)
        for _, ln in ipairs(comment_lines) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file.path, file.hunks)
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
        local comment_lines = collect_comment_lines(current_file.path, current_file.hunks)
        for i = #comment_lines, 1, -1 do
            if comment_lines[i] < cursor_line then
                M.jump_to(current_file.path, comment_lines[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file.path, file.hunks)
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
