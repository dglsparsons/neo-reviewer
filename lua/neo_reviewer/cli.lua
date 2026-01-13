local Job = require("plenary.job")
local config = require("neo_reviewer.config")

---@class NRPRInfo
---@field number integer PR number
---@field title string PR title
---@field head_ref string Head branch name
---@field head_sha string Head commit SHA
---@field base_ref string Base branch name
---@field owner string Repository owner
---@field repo string Repository name

---@class NRCheckoutInfo
---@field prev_branch string? Previous branch name

---@class NRCommentData
---@field path string File path
---@field line integer Line number
---@field side string Side of the diff ("LEFT" or "RIGHT")
---@field body string Comment body
---@field start_line? integer Start line for multi-line comments
---@field start_side? string Start side for multi-line comments

---@class NRCommentResponse
---@field success boolean
---@field comment_id? integer
---@field html_url? string
---@field error? string

---@class NRCommentsResponse
---@field comments NRComment[]

---@class NRCLIModule
local M = {}

---@return string?
function M.get_git_root()
    local result = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
    if vim.v.shell_error ~= 0 or #result == 0 then
        return nil
    end
    return result[1]
end

---@return string? owner
---@return string? repo
function M.get_git_remote()
    local result = vim.fn.systemlist("git remote get-url origin 2>/dev/null")
    if vim.v.shell_error ~= 0 or #result == 0 then
        return nil, nil
    end
    local url = result[1]
    local owner, repo = url:match("github%.com[:/]([^/]+)/([^/%.]+)")
    if repo then
        repo = repo:gsub("%.git$", "")
    end
    return owner, repo
end

---@return string?
function M.get_current_branch()
    local result = vim.fn.systemlist("git branch --show-current 2>/dev/null")
    if vim.v.shell_error ~= 0 or #result == 0 then
        return nil
    end
    return result[1]
end

---@return boolean
function M.is_worktree_dirty()
    local status = vim.fn.systemlist("git status --porcelain 2>/dev/null")
    return #status > 0
end

---@param callback fun(pr_info: NRPRInfo?, err: string?)
function M.get_pr_for_branch(callback)
    local owner, repo = M.get_git_remote()
    if not owner or not repo then
        callback(nil, "Not in a git repository with GitHub remote")
        return
    end

    Job:new({
        command = "gh",
        args = { "pr", "view", "--json", "number,title,headRefName,headRefOid,baseRefName" },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok then
                    callback({
                        number = data.number,
                        title = data.title,
                        head_ref = data.headRefName,
                        head_sha = data.headRefOid,
                        base_ref = data.baseRefName,
                        owner = owner,
                        repo = repo,
                    }, nil)
                else
                    callback(nil, "Failed to parse PR data")
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, "No PR found for current branch: " .. stderr)
            end
        end),
    }):start()
end

---@param pr_ref integer|string PR number or URL
---@param callback fun(checkout_info: NRCheckoutInfo?, err: string?)
function M.checkout_pr(pr_ref, callback)
    local prev_branch = M.get_current_branch()

    Job:new({
        command = "gh",
        args = { "pr", "checkout", tostring(pr_ref) },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                callback({ prev_branch = prev_branch }, nil)
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, "Failed to checkout PR: " .. stderr)
            end
        end),
    }):start()
end

---@param prev_branch string
---@param callback fun(ok: boolean, err: string?)
function M.restore_branch(prev_branch, callback)
    Job:new({
        command = "git",
        args = { "checkout", prev_branch },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                callback(true, nil)
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(false, "Failed to restore branch: " .. stderr)
            end
        end),
    }):start()
end

---@param url string
---@param callback fun(data: NRReviewData?, err: string?)
function M.fetch_pr(url, callback)
    Job:new({
        command = config.values.cli_path,
        args = { "fetch", "--url", url },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok then
                    callback(data, nil)
                else
                    callback(nil, "Failed to parse JSON: " .. output)
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, "CLI error: " .. stderr)
            end
        end),
    }):start()
end

---@param url string
---@param comment NRCommentData
---@param callback fun(data: NRCommentResponse?, err: string?)
function M.add_comment(url, comment, callback)
    local args = {
        "comment",
        "--url",
        url,
        "--path",
        comment.path,
        "--line",
        tostring(comment.line),
        "--side",
        comment.side,
        "--body",
        comment.body,
    }

    if comment.start_line then
        table.insert(args, "--start-line")
        table.insert(args, tostring(comment.start_line))
    end

    if comment.start_side then
        table.insert(args, "--start-side")
        table.insert(args, comment.start_side)
    end

    Job:new({
        command = config.values.cli_path,
        args = args,
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok and data.success then
                    callback(data, nil)
                else
                    callback(nil, data and data.error or "Unknown error")
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, stderr)
            end
        end),
    }):start()
end

---@param url string
---@param callback fun(comments: NRComment[]?, err: string?)
function M.fetch_comments(url, callback)
    Job:new({
        command = config.values.cli_path,
        args = { "comments", "--url", url },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok then
                    callback(data.comments, nil)
                else
                    callback(nil, "Failed to parse JSON")
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, stderr)
            end
        end),
    }):start()
end

---@param url string
---@param comment_id integer
---@param body string
---@param callback fun(data: NRCommentResponse?, err: string?)
function M.reply_to_comment(url, comment_id, body, callback)
    Job:new({
        command = config.values.cli_path,
        args = {
            "reply",
            "--url",
            url,
            "--comment-id",
            tostring(comment_id),
            "--body",
            body,
        },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok and data.success then
                    callback(data, nil)
                else
                    callback(nil, data and data.error or "Unknown error")
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, stderr)
            end
        end),
    }):start()
end

---@param callback fun(ok: boolean, output: string)
function M.check_auth(callback)
    Job:new({
        command = config.values.cli_path,
        args = { "auth" },
        on_exit = vim.schedule_wrap(function(j, code)
            local output = table.concat(j:result(), "\n")
            callback(code == 0, output)
        end),
    }):start()
end

---@param url string
---@param event string
---@param body? string
---@param callback fun(ok: boolean, err: string?)
function M.submit_review(url, event, body, callback)
    local args = { "submit", "--url", url, "--event", event }
    if body then
        table.insert(args, "--body")
        table.insert(args, body)
    end

    Job:new({
        command = config.values.cli_path,
        args = args,
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok and data.success then
                    callback(true, nil)
                else
                    callback(false, data and data.error or "Unknown error")
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(false, stderr)
            end
        end),
    }):start()
end

---@param callback fun(data: NRDiffData?, err: string?)
function M.get_local_diff(callback)
    Job:new({
        command = config.values.cli_path,
        args = { "diff" },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                local output = table.concat(j:result(), "\n")
                local ok, data = pcall(vim.json.decode, output)
                if ok then
                    callback(data, nil)
                else
                    callback(nil, "Failed to parse JSON: " .. output)
                end
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, "CLI error: " .. stderr)
            end
        end),
    }):start()
end

return M
