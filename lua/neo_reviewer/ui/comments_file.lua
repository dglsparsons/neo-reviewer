---@class NRCommentsFileModule
local M = {}

local COMMENTS_FILE = "REVIEW_COMMENTS.md"

---@return string
function M.get_path()
    local state = require("neo_reviewer.state")
    local git_root = state.get_git_root()
    if git_root then
        return git_root .. "/" .. COMMENTS_FILE
    end
    return vim.fn.getcwd() .. "/" .. COMMENTS_FILE
end

function M.clear()
    local path = M.get_path()
    os.remove(path)
end

local function ensure_file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    file = io.open(path, "w")
    if file then
        file:write("# Review Comments\n\n")
        file:close()
        return true
    end
    return false
end

---@param file_path string
---@param line integer
---@param end_line integer
---@param body string
---@return boolean
function M.write(file_path, line, end_line, body)
    local path = M.get_path()

    if not ensure_file_exists(path) then
        vim.notify("Failed to open " .. COMMENTS_FILE, vim.log.levels.ERROR)
        return false
    end

    local file = io.open(path, "a")
    if not file then
        vim.notify("Failed to open " .. COMMENTS_FILE, vim.log.levels.ERROR)
        return false
    end

    local line_spec
    if end_line and end_line ~= line then
        line_spec = string.format("%d-%d", line, end_line)
    else
        line_spec = tostring(line)
    end

    file:write(string.format("## file=%s:line=%s\n", file_path, line_spec))
    file:write(body .. "\n\n")
    file:close()

    return true
end

return M
