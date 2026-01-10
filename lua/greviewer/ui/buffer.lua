---@class GReviewerBufferModule
local M = {}

---@return GReviewerFile?
function M.get_current_file_from_buffer()
    local ok, file = pcall(vim.api.nvim_buf_get_var, 0, "greviewer_file")
    if ok then
        return file
    end
    return nil
end

---@return string?
function M.get_pr_url_from_buffer()
    local ok, url = pcall(vim.api.nvim_buf_get_var, 0, "greviewer_pr_url")
    if ok then
        return url
    end
    return nil
end

return M
