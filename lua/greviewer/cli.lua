local Job = require("plenary.job")
local config = require("greviewer.config")

local M = {}

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

function M.get_current_branch()
    local result = vim.fn.systemlist("git branch --show-current 2>/dev/null")
    if vim.v.shell_error ~= 0 or #result == 0 then
        return nil
    end
    return result[1]
end

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

function M.checkout_pr(pr_number, callback)
    local stashed = false
    local prev_branch = M.get_current_branch()

    local status = vim.fn.systemlist("git status --porcelain 2>/dev/null")
    if #status > 0 then
        vim.fn.system("git stash push -m 'greviewer: auto-stash'")
        if vim.v.shell_error == 0 then
            stashed = true
        end
    end

    Job:new({
        command = "gh",
        args = { "pr", "checkout", tostring(pr_number) },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                callback({ stashed = stashed, prev_branch = prev_branch }, nil)
            else
                if stashed then
                    vim.fn.system("git stash pop")
                end
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(nil, "Failed to checkout PR: " .. stderr)
            end
        end),
    }):start()
end

function M.restore_branch(prev_branch, stashed, callback)
    Job:new({
        command = "git",
        args = { "checkout", prev_branch },
        on_exit = vim.schedule_wrap(function(j, code)
            if code == 0 then
                if stashed then
                    vim.fn.system("git stash pop")
                end
                callback(true, nil)
            else
                local stderr = table.concat(j:stderr_result(), "\n")
                callback(false, "Failed to restore branch: " .. stderr)
            end
        end),
    }):start()
end

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

return M
