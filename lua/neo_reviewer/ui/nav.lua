---@class NRAINavItem
---@field file string File path
---@field change_block_index integer 0-based change block index
---@field line integer Line number to jump to
---@field end_line integer Last line in the change block

---@class NRNavModule
local M = {}

local buffer = require("neo_reviewer.ui.buffer")
local comment_ns = vim.api.nvim_create_namespace("nr_comments")

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
    local seen_by_block = {}

    for _, step in ipairs(review.ai_analysis.steps or {}) do
        for _, block_ref in ipairs(step.change_blocks or {}) do
            local file = review.files_by_path[block_ref.file]
            if file then
                local block = file.change_blocks[block_ref.change_block_index + 1]
                if block then
                    local block_key = block_ref.file .. ":" .. tostring(block_ref.change_block_index)
                    if not seen_by_block[block_key] and type(block.start_line) == "number" then
                        local start_line = block.start_line
                        local end_line = block.end_line or start_line
                        local current_start, current_end = buffer.get_change_block_range_for_file(
                            file,
                            block_ref.change_block_index,
                            start_line,
                            end_line
                        )
                        table.insert(nav_list, {
                            file = block_ref.file,
                            change_block_index = block_ref.change_block_index,
                            line = current_start or start_line,
                            end_line = current_end or end_line,
                        })
                        seen_by_block[block_key] = true
                    end
                end
            end
        end
    end

    return #nav_list > 0 and nav_list or nil
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
            return i
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

---@param file NRFile
---@param line integer
---@return integer|nil
local function find_change_block_index_at_line(file, line)
    for i, block in ipairs(file.change_blocks or {}) do
        if type(block.start_line) == "number" then
            local start_line = block.start_line
            local end_line = block.end_line or start_line
            local current_start, current_end = buffer.get_change_block_range_for_file(file, i - 1, start_line, end_line)
            local anchor_start = current_start or start_line
            local anchor_end = current_end or end_line

            if block.kind == "delete" then
                if line == anchor_start or line == anchor_start - 1 then
                    return i - 1
                end
            elseif line >= anchor_start and line <= anchor_end then
                return i - 1
            end
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
        local change_block_index = find_change_block_index_at_line(file, cursor_line)
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
---@param file NRFile
---@return integer?
local function get_comment_display_line(comment, file)
    local line = comment.line
    if type(line) ~= "number" then
        return nil
    end
    if comment.side == "LEFT" then
        line = map_old_line_to_new(file.change_blocks, line) or line
    end
    return buffer.map_line(file, line)
end

---@param file NRFile
---@return integer[]
local function collect_comment_lines(file)
    ---@type integer[]
    local lines = {}
    ---@type table<integer, boolean>
    local seen = {}

    local bufnr = buffer.get_buffer_for_file(file.path)
    if bufnr then
        local ok, mark_ids = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_comment_marks")
        if ok and type(mark_ids) == "table" then
            for _, mark_id in pairs(mark_ids) do
                local resolved_id = tonumber(mark_id)
                if resolved_id then
                    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, comment_ns, resolved_id, {})
                    if pos and #pos > 0 then
                        local line = pos[1] + 1
                        if not seen[line] then
                            table.insert(lines, line)
                            seen[line] = true
                        end
                    end
                end
            end

            if #lines > 0 then
                table.sort(lines)
                return lines
            end
        end

        local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, comment_ns, 0, -1, { details = true })
        for _, mark in ipairs(extmarks) do
            local details = mark[4] or {}
            local virt_text = details.virt_text or {}
            local has_comment = false
            for _, chunk in ipairs(virt_text) do
                if chunk[2] == "NRComment" then
                    has_comment = true
                    break
                end
            end
            if not has_comment then
                if details.virt_text_pos == "eol" then
                    has_comment = true
                elseif details.sign_text ~= nil then
                    has_comment = true
                end
            end
            if has_comment then
                local line = mark[2] + 1
                if not seen[line] then
                    table.insert(lines, line)
                    seen[line] = true
                end
            end
        end

        if #lines > 0 then
            table.sort(lines)
            return lines
        end
    end

    local state = require("neo_reviewer.state")
    local comments = state.get_comments_for_file(file.path)

    for _, comment in ipairs(comments) do
        if type(comment.in_reply_to_id) ~= "number" then
            local display_line = get_comment_display_line(comment, file)
            if display_line and not seen[display_line] then
                table.insert(lines, display_line)
                seen[display_line] = true
            end
        end
    end

    table.sort(lines)
    return lines
end

---@param file NRFile
---@return integer[]
local function collect_change_starts(file)
    ---@type integer[]
    local starts = {}
    ---@type table<integer, boolean>
    local seen = {}

    for i, block in ipairs(file.change_blocks or {}) do
        local start_line = block.start_line
        if type(start_line) == "number" then
            local end_line = block.end_line or start_line
            local current_start = buffer.get_change_block_range_for_file(file, i - 1, start_line, end_line)
            local line = current_start or start_line
            if not seen[line] then
                table.insert(starts, line)
                seen[line] = true
            end
        end
    end

    table.sort(starts)
    return starts
end

---@param review NRReview
---@return integer?
local function get_current_file_index(review)
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
        local change_starts = collect_change_starts(current_file)
        for _, ln in ipairs(change_starts) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                ai_ui.sync_to_location(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local starts = collect_change_starts(file)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local starts = collect_change_starts(file)
            if #starts > 0 then
                M.jump_to(file.path, starts[1])
                ai_ui.sync_to_location(file.path, starts[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local starts = collect_change_starts(file)
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
        local change_starts = collect_change_starts(current_file)
        for i = #change_starts, 1, -1 do
            if change_starts[i] < cursor_line then
                M.jump_to(current_file.path, change_starts[i])
                ai_ui.sync_to_location(current_file.path, change_starts[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local starts = collect_change_starts(file)
            if #starts > 0 then
                M.jump_to(file.path, starts[#starts])
                ai_ui.sync_to_location(file.path, starts[#starts])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local starts = collect_change_starts(file)
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
            local starts = collect_change_starts(file)
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
        local starts = collect_change_starts(file)
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
        local starts = collect_change_starts(file)
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
        local comment_lines = collect_comment_lines(current_file)
        for _, ln in ipairs(comment_lines) do
            if ln > cursor_line then
                M.jump_to(current_file.path, ln)
                return
            end
        end

        for i = current_idx + 1, #review.files do
            local file = review.files[i]
            local lines = collect_comment_lines(file)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    else
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file)
            if #lines > 0 then
                M.jump_to(file.path, lines[1])
                return
            end
        end
    end

    if wrap then
        for _, file in ipairs(review.files) do
            local lines = collect_comment_lines(file)
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
        local comment_lines = collect_comment_lines(current_file)
        for i = #comment_lines, 1, -1 do
            if comment_lines[i] < cursor_line then
                M.jump_to(current_file.path, comment_lines[i])
                return
            end
        end

        for i = current_idx - 1, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    else
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file)
            if #lines > 0 then
                M.jump_to(file.path, lines[#lines])
                return
            end
        end
    end

    if wrap then
        for i = #review.files, 1, -1 do
            local file = review.files[i]
            local lines = collect_comment_lines(file)
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
