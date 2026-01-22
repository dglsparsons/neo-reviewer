local config = require("neo_reviewer.config")

---@class NRSignsModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_signs")

local hl_groups_defined = false

local function define_highlights()
    if hl_groups_defined then
        return
    end
    hl_groups_defined = true

    vim.api.nvim_set_hl(0, "NRAdd", { fg = "#98c379", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRDelete", { fg = "#e06c75", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRChange", { fg = "#e5c07b", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRAddLine", { bg = "#2d3b2d", default = true })
    vim.api.nvim_set_hl(0, "NRDeleteLine", { bg = "#3b2d2d", default = true })
    vim.api.nvim_set_hl(0, "NRChangeLine", { bg = "#3b3b2d", default = true })
end

---@param bufnr integer
---@param hunks? NRHunk[]
function M.place(bufnr, hunks)
    define_highlights()

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    if not hunks then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, hunk in ipairs(hunks) do
        local changed_lookup = nil
        if hunk.hunk_type == "change" and hunk.changed_lines ~= nil then
            changed_lookup = {}
            for _, line_num in ipairs(hunk.changed_lines) do
                changed_lookup[line_num] = true
            end
        end

        for _, line_num in ipairs(hunk.added_lines or {}) do
            local row = line_num - 1
            if row >= 0 and row < line_count then
                local sign_text, sign_hl, line_hl
                local is_change = false
                if hunk.hunk_type == "change" then
                    if changed_lookup then
                        is_change = changed_lookup[line_num] == true
                    else
                        is_change = true
                    end
                end

                if hunk.hunk_type == "add" or (hunk.hunk_type == "change" and not is_change) then
                    sign_text = config.values.signs.add
                    sign_hl = "NRAdd"
                    line_hl = "NRAddLine"
                else
                    sign_text = config.values.signs.change
                    sign_hl = "NRChange"
                    line_hl = "NRChangeLine"
                end
                vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                    sign_text = sign_text,
                    sign_hl_group = sign_hl,
                    line_hl_group = line_hl,
                    priority = 10,
                })
            end
        end

        for _, line_num in ipairs(hunk.deleted_at or {}) do
            local row = math.max(line_num - 1, 0)
            if row < line_count then
                local existing = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, 0 }, {})
                if #existing == 0 then
                    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                        sign_text = config.values.signs.delete,
                        sign_hl_group = "NRDelete",
                        priority = 10,
                    })
                end
            end
        end
    end
end

---@param bufnr integer
---@param file_path string
function M.show(bufnr, file_path)
    local state = require("neo_reviewer.state")
    local file = state.get_file_by_path(file_path)
    if file then
        M.place(bufnr, file.hunks)
    end
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
