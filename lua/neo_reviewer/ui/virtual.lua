local state = require("neo_reviewer.state")

---@class NRVirtualModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_virtual")

local function define_highlights()
    vim.api.nvim_set_hl(0, "NRVirtualDelete", { fg = "#e06c75", bg = "#3b2d2d", default = true })
end

local function expand_all_in_buffer(bufnr, file)
    if not file.change_blocks then
        return
    end
    for _, block in ipairs(file.change_blocks) do
        if block.deletion_groups and #block.deletion_groups > 0 then
            if not state.is_change_expanded(file.path, block.start_line) then
                M.expand(bufnr, block, file.path)
            end
        end
    end
end

function M.apply_mode_to_buffer(bufnr, file)
    define_highlights()
    expand_all_in_buffer(bufnr, file)
end

function M.toggle_at_cursor()
    define_highlights()

    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local ok, file = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_file")
    if not ok or not file then
        vim.notify("Current buffer is not part of the active review", vim.log.levels.WARN)
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local block = M.find_change_block_at_line(file.change_blocks, cursor[1])
    if not block then
        vim.notify("No change block at cursor", vim.log.levels.INFO)
        return
    end

    if not block.deletion_groups or #block.deletion_groups == 0 then
        vim.notify("This change block has no deleted lines to preview", vim.log.levels.INFO)
        return
    end

    if state.is_change_expanded(file.path, block.start_line) then
        M.collapse(bufnr, block, file.path)
    else
        M.expand(bufnr, block, file.path)
    end
end

---@param bufnr integer
---@param block NRChangeBlock
---@param file_path string
function M.expand(bufnr, block, file_path)
    local groups = block.deletion_groups or {}
    if #groups == 0 then
        return
    end

    ---@type integer[]
    local extmark_ids = {}
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, group in ipairs(groups) do
        ---@type {[1]: string, [2]: string}[][]
        local virt_lines = {}

        for _, old_line in ipairs(group.old_lines) do
            table.insert(virt_lines, {
                { old_line, "NRVirtualDelete" },
            })
        end

        -- Each deletion group anchors to its own position directly.
        -- With virt_lines_above=true, virtual lines appear exactly where deleted content was.
        local row = math.max(group.anchor_line - 1, 0)
        local above = true

        if row >= line_count then
            row = math.max(line_count - 1, 0)
            above = false -- EOF deletions: show after last line, not above it
        end

        local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
            virt_lines = virt_lines,
            virt_lines_above = above,
        })

        table.insert(extmark_ids, extmark_id)
    end

    state.set_change_expanded(file_path, block.start_line, extmark_ids)
end

---@param bufnr integer
---@param block NRChangeBlock
---@param file_path string
function M.collapse(bufnr, block, file_path)
    local extmark_ids = state.get_change_extmarks(file_path, block.start_line)

    if extmark_ids then
        for _, id in ipairs(extmark_ids) do
            pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
        end
    end

    state.set_change_expanded(file_path, block.start_line, nil)
end

---@param change_blocks? NRChangeBlock[]
---@param line integer
---@return NRChangeBlock?
function M.find_change_block_at_line(change_blocks, line)
    if not change_blocks then
        return nil
    end

    for _, block in ipairs(change_blocks) do
        local block_end = block.end_line or block.start_line

        if block.kind == "delete" then
            if line == block.start_line or line == block.start_line - 1 then
                return block
            end
        else
            if line >= block.start_line and line <= block_end then
                return block
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
