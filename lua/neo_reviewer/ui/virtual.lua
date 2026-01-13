local state = require("neo_reviewer.state")

---@class NRDeletionGroup
---@field position integer Original line position where deletion occurred (from deleted_at)
---@field anchor_line integer Line number to anchor the extmark to
---@field lines string[] Deleted line contents

---@class NRVirtualModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_virtual")

local function define_highlights()
    vim.api.nvim_set_hl(0, "NRVirtualDelete", { fg = "#e06c75", bg = "#3b2d2d", default = true })
end

---Groups deleted lines by their position and determines the anchor point.
---
---Each deletion group anchors to its own position (deleted_at value). With
---virt_lines_above=true, this places the virtual lines immediately above
---the line at that position - exactly where the deleted content was.
---@param hunk NRHunk
---@return NRDeletionGroup[]
local function group_deletions_with_anchors(hunk)
    if not hunk.deleted_at or #hunk.deleted_at == 0 then
        return {}
    end

    ---@type NRDeletionGroup[]
    local groups = {}
    ---@type NRDeletionGroup?
    local current_group = nil

    for i, old_line in ipairs(hunk.old_lines) do
        local pos = hunk.deleted_at[i] or hunk.start

        if current_group and current_group.position == pos then
            table.insert(current_group.lines, old_line)
        else
            current_group = {
                position = pos,
                anchor_line = pos,
                lines = { old_line },
            }
            table.insert(groups, current_group)
        end
    end

    return groups
end

local function expand_all_in_buffer(bufnr, file)
    if not file.hunks then
        return
    end
    for _, hunk in ipairs(file.hunks) do
        if hunk.old_lines and #hunk.old_lines > 0 then
            if not state.is_hunk_expanded(file.path, hunk.start) then
                M.expand(bufnr, hunk, file.path)
            end
        end
    end
end

local function collapse_all_in_buffer(bufnr, file)
    if not file.hunks then
        return
    end
    for _, hunk in ipairs(file.hunks) do
        if hunk.old_lines and #hunk.old_lines > 0 then
            if state.is_hunk_expanded(file.path, hunk.start) then
                M.collapse(bufnr, hunk, file.path)
            end
        end
    end
end

function M.apply_mode_to_buffer(bufnr, file)
    define_highlights()
    if state.is_showing_old_code() then
        expand_all_in_buffer(bufnr, file)
    end
end

function M.toggle_at_cursor()
    define_highlights()

    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local new_mode = not state.is_showing_old_code()
    state.set_show_old_code(new_mode)

    for bufnr, _ in pairs(state.get_applied_buffers()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local ok, file = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_file")
            if ok and file then
                if new_mode then
                    expand_all_in_buffer(bufnr, file)
                else
                    collapse_all_in_buffer(bufnr, file)
                end
            end
        end
    end
end

---@param bufnr integer
---@param hunk NRHunk
---@param file_path string
function M.expand(bufnr, hunk, file_path)
    local groups = group_deletions_with_anchors(hunk)

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
                { old_line, "NRVirtualDelete" },
            })
        end

        -- Use anchor_line for positioning:
        -- - CHANGE hunks: first added line (stable content anchor)
        -- - DELETE-only hunks: line above deletion (stable neighbor anchor)
        local row = math.max(group.anchor_line - 1, 0)
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
---@param hunk NRHunk
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

---@param hunks? NRHunk[]
---@param line integer
---@return NRHunk?
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
