---@class NRBufferModule
local M = {}

local change_block_ns = vim.api.nvim_create_namespace("nr_change_blocks")

---@return NRFile?
function M.get_current_file_from_buffer()
    local ok, file = pcall(vim.api.nvim_buf_get_var, 0, "nr_file")
    if ok then
        return file
    end
    return nil
end

---@return string?
function M.get_pr_url_from_buffer()
    local ok, url = pcall(vim.api.nvim_buf_get_var, 0, "nr_pr_url")
    if ok then
        return url
    end
    return nil
end

---@param file_path string
---@return integer|nil
function M.get_buffer_for_file(file_path)
    local state = require("neo_reviewer.state")

    for bufnr, _ in pairs(state.get_applied_buffers()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local ok, file = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_file")
            if ok and file and file.path == file_path then
                return bufnr
            end
        end
    end

    return nil
end

---@param bufnr integer
---@param file NRFile
function M.place_change_block_marks(bufnr, file)
    vim.api.nvim_buf_clear_namespace(bufnr, change_block_ns, 0, -1)

    ---@type table<integer, integer>
    local marks = {}
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for block_idx, block in ipairs(file.change_blocks or {}) do
        local start_line = block.start_line
        if type(start_line) == "number" then
            local end_line = block.end_line or start_line
            local row = math.max(start_line - 1, 0)
            local end_row = math.max(end_line - 1, row)

            if line_count > 0 then
                if row >= line_count then
                    row = math.max(line_count - 1, 0)
                end
                if end_row >= line_count then
                    end_row = math.max(line_count - 1, row)
                end
            end

            local id = vim.api.nvim_buf_set_extmark(bufnr, change_block_ns, row, 0, {
                end_row = end_row,
                end_col = 0,
                right_gravity = false,
                end_right_gravity = false,
            })

            marks[block_idx] = id
        end
    end

    pcall(vim.api.nvim_buf_set_var, bufnr, "nr_change_block_marks", marks)
end

---@param bufnr integer
function M.clear_change_block_marks(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, change_block_ns, 0, -1)
    pcall(vim.api.nvim_buf_del_var, bufnr, "nr_change_block_marks")
end

---@param bufnr integer
---@param change_block_index integer
---@param fallback_start integer
---@param fallback_end integer
---@return integer
---@return integer
function M.get_change_block_range(bufnr, change_block_index, fallback_start, fallback_end)
    local ok, marks = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_change_block_marks")
    if not ok or type(marks) ~= "table" then
        return fallback_start, fallback_end
    end

    local mark_id = marks[change_block_index + 1]
    if not mark_id then
        return fallback_start, fallback_end
    end

    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, change_block_ns, mark_id, { details = true })
    if not pos or #pos == 0 then
        return fallback_start, fallback_end
    end

    local row = pos[1]
    local details = pos[3] or {}
    local end_row = details.end_row or row

    return row + 1, end_row + 1
end

---@param file NRFile
---@param change_block_index integer
---@param fallback_start integer
---@param fallback_end integer
---@return integer
---@return integer
function M.get_change_block_range_for_file(file, change_block_index, fallback_start, fallback_end)
    local bufnr = M.get_buffer_for_file(file.path)
    if not bufnr then
        return fallback_start, fallback_end
    end

    return M.get_change_block_range(bufnr, change_block_index, fallback_start, fallback_end)
end

---@param file NRFile
---@param change_block_index integer
---@param line integer
---@return integer?
function M.map_line_in_block(file, change_block_index, line)
    if type(line) ~= "number" then
        return nil
    end

    local block = file.change_blocks and file.change_blocks[change_block_index + 1]
    if not block or type(block.start_line) ~= "number" then
        return line
    end

    local start_line = block.start_line
    local end_line = block.end_line or start_line
    local current_start = M.get_change_block_range_for_file(file, change_block_index, start_line, end_line)
    if type(current_start) ~= "number" then
        return line
    end

    return current_start + (line - start_line)
end

---@param file NRFile
---@param line integer
---@return integer?
function M.map_line(file, line)
    if type(line) ~= "number" then
        return nil
    end

    for block_idx, block in ipairs(file.change_blocks or {}) do
        local start_line = block.start_line
        if type(start_line) == "number" then
            local end_line = block.end_line or start_line
            if block.kind == "delete" then
                if line == start_line or line == start_line - 1 then
                    return M.map_line_in_block(file, block_idx - 1, line)
                end
            elseif line >= start_line and line <= end_line then
                return M.map_line_in_block(file, block_idx - 1, line)
            end
        end
    end

    return line
end

return M
