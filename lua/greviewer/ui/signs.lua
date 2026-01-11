local config = require("greviewer.config")

---@class GReviewerSignsModule
local M = {}

local ns = vim.api.nvim_create_namespace("greviewer_signs")

local hl_groups_defined = false

local function define_highlights()
    if hl_groups_defined then
        return
    end
    hl_groups_defined = true

    vim.api.nvim_set_hl(0, "GReviewerAdd", { fg = "#98c379", bold = true, default = true })
    vim.api.nvim_set_hl(0, "GReviewerDelete", { fg = "#e06c75", bold = true, default = true })
    vim.api.nvim_set_hl(0, "GReviewerChange", { fg = "#e5c07b", bold = true, default = true })
    vim.api.nvim_set_hl(0, "GReviewerAddLine", { bg = "#2d3b2d", default = true })
    vim.api.nvim_set_hl(0, "GReviewerDeleteLine", { bg = "#3b2d2d", default = true })
    vim.api.nvim_set_hl(0, "GReviewerChangeLine", { bg = "#3b3b2d", default = true })
end

---@param bufnr integer
---@param hunks? GReviewerHunk[]
function M.place(bufnr, hunks)
    define_highlights()

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    if not hunks then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, hunk in ipairs(hunks) do
        for _, line_num in ipairs(hunk.added_lines or {}) do
            local row = line_num - 1
            if row >= 0 and row < line_count then
                local sign_text, sign_hl, line_hl
                if hunk.hunk_type == "add" then
                    sign_text = config.values.signs.add
                    sign_hl = "GReviewerAdd"
                    line_hl = "GReviewerAddLine"
                else
                    sign_text = config.values.signs.change
                    sign_hl = "GReviewerChange"
                    line_hl = "GReviewerChangeLine"
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
                        sign_hl_group = "GReviewerDelete",
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
    local state = require("greviewer.state")
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
