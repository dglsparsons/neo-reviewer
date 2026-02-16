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

local function collapse_all_in_buffer(bufnr, file)
    if not file.change_blocks then
        return
    end
    for _, block in ipairs(file.change_blocks) do
        if block.deletion_groups and #block.deletion_groups > 0 then
            M.collapse(bufnr, block, file.path)
        end
    end
end

---@param bufnr integer
---@param file NRFile
---@param show_old_code? boolean
function M.apply_mode_to_buffer(bufnr, file, show_old_code)
    define_highlights()
    if show_old_code == false then
        collapse_all_in_buffer(bufnr, file)
        return
    end
    expand_all_in_buffer(bufnr, file)
end

function M.toggle_review_mode()
    define_highlights()

    local review = state.get_review()
    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local current_bufnr = vim.api.nvim_get_current_buf()
    local ok, current_file = pcall(vim.api.nvim_buf_get_var, current_bufnr, "nr_file")
    if not ok or not current_file then
        vim.notify("Current buffer is not part of the active review", vim.log.levels.WARN)
        return
    end

    local show_old_code = not state.is_showing_old_code()
    state.set_show_old_code(show_old_code)

    local applied = false
    for bufnr, _ in pairs(state.get_applied_buffers()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local file_ok, file = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_file")
            if file_ok and file then
                M.apply_mode_to_buffer(bufnr, file, show_old_code)
                applied = true
            end
        end
    end

    if not applied then
        M.apply_mode_to_buffer(current_bufnr, current_file, show_old_code)
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

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
