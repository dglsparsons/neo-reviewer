local state = require("greviewer.state")

---@class GReviewerDeletionGroup
---@field position integer Line position where deletion occurred
---@field lines string[] Deleted line contents

---@class GReviewerVirtualModule
local M = {}

local ns = vim.api.nvim_create_namespace("greviewer_virtual")

local function define_highlights()
    vim.api.nvim_set_hl(0, "GReviewerVirtualDelete", { fg = "#e06c75", bg = "#3b2d2d", default = true })
end

---@param hunk GReviewerHunk
---@return GReviewerDeletionGroup[]
local function group_deletions_by_position(hunk)
    if not hunk.deleted_at or #hunk.deleted_at == 0 then
        return {}
    end

    ---@type GReviewerDeletionGroup[]
    local groups = {}
    ---@type GReviewerDeletionGroup?
    local current_group = nil

    for i, old_line in ipairs(hunk.old_lines) do
        local pos = hunk.deleted_at[i] or hunk.start

        if current_group and current_group.position == pos then
            table.insert(current_group.lines, old_line)
        else
            current_group = { position = pos, lines = { old_line } }
            table.insert(groups, current_group)
        end
    end

    return groups
end

function M.toggle_at_cursor()
    define_highlights()

    local buffer = require("greviewer.ui.buffer")
    local file = buffer.get_current_file_from_buffer()
    if not file then
        vim.notify("Not in a review buffer", vim.log.levels.WARN)
        return
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local hunk = M.find_hunk_at_line(file.hunks, line)

    if not hunk then
        vim.notify("No changes at cursor position", vim.log.levels.INFO)
        return
    end

    if #hunk.old_lines == 0 then
        vim.notify("No old content to show (pure addition)", vim.log.levels.INFO)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local is_expanded = state.is_hunk_expanded(file.path, hunk.start)

    if is_expanded then
        M.collapse(bufnr, hunk, file.path)
    else
        M.expand(bufnr, hunk, file.path)
    end
end

---@param bufnr integer
---@param hunk GReviewerHunk
---@param file_path string
function M.expand(bufnr, hunk, file_path)
    local groups = group_deletions_by_position(hunk)

    if #groups == 0 then
        return
    end

    ---@type integer[]
    local extmark_ids = {}
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, group in ipairs(groups) do
        ---@type {[1]: string, [2]: string}[][]
        local virt_lines = {}

        for _, old_line in ipairs(group.lines) do
            table.insert(virt_lines, {
                { old_line, "GReviewerVirtualDelete" },
            })
        end

        local row = math.max(group.position - 1, 0)
        if row >= line_count then
            row = line_count - 1
        end

        local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
            virt_lines = virt_lines,
            virt_lines_above = true,
        })

        table.insert(extmark_ids, extmark_id)
    end

    state.set_hunk_expanded(file_path, hunk.start, extmark_ids)
end

---@param bufnr integer
---@param hunk GReviewerHunk
---@param file_path string
function M.collapse(bufnr, hunk, file_path)
    local extmark_ids = state.get_hunk_extmarks(file_path, hunk.start)

    if extmark_ids then
        for _, id in ipairs(extmark_ids) do
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
        end
    end

    state.set_hunk_expanded(file_path, hunk.start, nil)
end

---@param hunks? GReviewerHunk[]
---@param line integer
---@return GReviewerHunk?
function M.find_hunk_at_line(hunks, line)
    if not hunks then
        return nil
    end

    for _, hunk in ipairs(hunks) do
        local hunk_end = hunk.start + math.max(hunk.count - 1, 0)

        if hunk.hunk_type == "delete" then
            if line == hunk.start or line == hunk.start - 1 then
                return hunk
            end
        else
            if line >= hunk.start and line <= hunk_end then
                return hunk
            end
        end
    end

    return nil
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
