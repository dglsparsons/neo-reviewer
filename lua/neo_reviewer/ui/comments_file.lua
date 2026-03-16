---@class NRCommentsFileModule
local M = {}

local COMMENTS_FILE = "REVIEW_COMMENTS.md"
local HEADER = "# Diff comments\n\n"

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

---@param line integer
---@param end_line integer
---@return string
local function build_line_spec(line, end_line)
    if end_line and end_line ~= line then
        return string.format("%d-%d", line, end_line)
    end
    return tostring(line)
end

---@param comment_id integer
---@param file_path string
---@param line integer
---@param end_line integer
---@return string
local function build_comment_heading(comment_id, file_path, line, end_line)
    return string.format("## Comment %d (%s:%s)\n", comment_id, file_path, build_line_spec(line, end_line))
end

---@param comments table[]
---@return boolean
function M.write_all(comments)
    local path = M.get_path()
    local file = io.open(path, "w")
    if not file then
        vim.notify("Failed to open " .. COMMENTS_FILE, vim.log.levels.ERROR)
        return false
    end

    file:write(HEADER)

    for _, comment in ipairs(comments or {}) do
        if type(comment.id) == "number" and type(comment.line) == "number" and type(comment.path) == "string" then
            local line = comment.start_line or comment.line
            local end_line = comment.line
            file:write(build_comment_heading(comment.id, comment.path, line, end_line))
            file:write((comment.body or "") .. "\n\n")
        end
    end

    file:close()
    return true
end

return M
