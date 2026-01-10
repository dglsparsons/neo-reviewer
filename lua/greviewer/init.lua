---@class GReviewerAddCommentOpts
---@field line1? integer Start line from visual selection
---@field line2? integer End line from visual selection

---@class GReviewerModule
local M = {}

---@param opts? GReviewerPartialConfig
function M.setup(opts)
    local config = require("greviewer.config")
    config.setup(opts)

    if vim.fn.executable(config.values.cli_path) == 0 then
        vim.notify("greviewer CLI not found. Please install it with: cargo install --path cli", vim.log.levels.WARN)
    end

    vim.api.nvim_create_user_command("GReviewPR", function(ctx)
        local arg = ctx.args
        if arg and arg ~= "" then
            M.review(arg)
        else
            M.review()
        end
    end, { nargs = "?", desc = "Open PR review" })

    vim.api.nvim_create_user_command("GReviewDiff", function()
        M.review_diff()
    end, { desc = "Review local git diff (staged + unstaged changes)" })

    vim.api.nvim_create_user_command("GAddComment", function(ctx)
        M.add_comment({ line1 = ctx.line1, line2 = ctx.line2 })
    end, { range = true, desc = "Add comment at cursor or on visual selection" })

    vim.api.nvim_create_user_command("GApprove", function()
        M.approve()
    end, { desc = "Approve the PR" })

    vim.api.nvim_create_user_command("GRequestChanges", function(ctx)
        M.request_changes(ctx.args ~= "" and ctx.args or nil)
    end, { nargs = "?", desc = "Request changes on the PR" })
end

---@param url_or_number? string|integer
function M.review(url_or_number)
    if url_or_number == nil then
        M.open()
    elseif type(url_or_number) == "number" or tonumber(url_or_number) then
        local pr_number = tonumber(url_or_number) --[[@as integer]]
        M.open_with_checkout(pr_number)
    else
        ---@cast url_or_number string
        M.open_url(url_or_number)
    end
end

function M.open()
    local cli = require("greviewer.cli")

    cli.get_pr_for_branch(function(pr_info, err)
        if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        local url = string.format("https://github.com/%s/%s/pull/%d", pr_info.owner, pr_info.repo, pr_info.number)
        vim.notify(string.format("Found PR #%d: %s", pr_info.number, pr_info.title), vim.log.levels.INFO)

        M.fetch_and_enable(url)
    end)
end

---@param pr_number integer
function M.open_with_checkout(pr_number)
    local cli = require("greviewer.cli")
    local state = require("greviewer.state")

    vim.notify(string.format("Checking out PR #%d...", pr_number), vim.log.levels.INFO)

    cli.checkout_pr(pr_number, function(checkout_info, err)
        if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        cli.get_pr_for_branch(function(pr_info, pr_err)
            if pr_err then
                vim.notify(pr_err, vim.log.levels.ERROR)
                return
            end

            local url = string.format("https://github.com/%s/%s/pull/%d", pr_info.owner, pr_info.repo, pr_info.number)

            M.fetch_and_enable(url, function()
                state.set_checkout_state(checkout_info.prev_branch, checkout_info.stashed)
            end)
        end)
    end)
end

---@param url string
function M.open_url(url)
    M.fetch_and_enable(url)
end

function M.review_diff()
    local cli = require("greviewer.cli")
    local state = require("greviewer.state")

    vim.notify("Getting local diff...", vim.log.levels.INFO)

    cli.get_local_diff(function(data, err)
        if err then
            vim.notify("Failed to get diff: " .. err, vim.log.levels.ERROR)
            return
        end

        if #data.files == 0 then
            vim.notify("No changes to review", vim.log.levels.WARN)
            return
        end

        state.clear_review()
        state.set_local_review(data)

        local comments_file = require("greviewer.ui.comments_file")
        comments_file.clear()

        M.enable_overlay()

        vim.notify(string.format("Local diff review enabled (%d files changed)", #data.files), vim.log.levels.INFO)
    end)
end

---@param url string
---@param on_ready? fun()
function M.fetch_and_enable(url, on_ready)
    local cli = require("greviewer.cli")
    local state = require("greviewer.state")

    vim.notify("Fetching PR data...", vim.log.levels.INFO)

    cli.fetch_pr(url, function(data, err)
        if err then
            vim.notify("Failed to fetch PR: " .. err, vim.log.levels.ERROR)
            return
        end

        state.clear_review()
        local review = state.set_review(data)
        review.url = url

        if on_ready then
            on_ready()
        end

        M.enable_overlay()

        vim.notify(
            string.format(
                "Review mode enabled for PR #%d: %s (%d files changed)",
                data.pr.number,
                data.pr.title,
                #data.files
            ),
            vim.log.levels.INFO
        )
    end)
end

function M.enable_overlay()
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        return
    end

    local autocmd_id = vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
        callback = function(args)
            M.apply_overlay_to_buffer(args.buf)
        end,
    })
    state.set_autocmd_id(autocmd_id)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            M.apply_overlay_to_buffer(buf)
        end
    end
end

---@param bufnr integer
function M.apply_overlay_to_buffer(bufnr)
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        return
    end

    if state.is_buffer_applied(bufnr) then
        return
    end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname == "" then
        return
    end

    local cwd = vim.fn.getcwd()
    local relative_path = bufname
    if bufname:sub(1, #cwd) == cwd then
        relative_path = bufname:sub(#cwd + 2)
    end

    local file = state.get_file_by_path(relative_path)
    if not file then
        return
    end

    state.mark_buffer_applied(bufnr)

    vim.api.nvim_buf_set_var(bufnr, "greviewer_file", file)
    if review.url then
        vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", review.url)
    end

    local signs = require("greviewer.ui.signs")
    signs.place(bufnr, file.hunks)

    if not state.is_local_review() then
        local comments_ui = require("greviewer.ui.comments")
        comments_ui.show_existing(bufnr, file.path)
    end
end

function M.show_file_picker()
    local state = require("greviewer.state")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local telescope_ok, telescope = pcall(require, "telescope.pickers")
    if not telescope_ok then
        M.show_file_picker_fallback()
        return
    end

    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    ---@type {display: string, path: string, idx: integer}[]
    local entries = {}
    for i, file in ipairs(review.files) do
        local icon = ({ added = "+", deleted = "-", modified = "~", renamed = "R" })[file.status] or "?"
        table.insert(entries, {
            display = string.format("[%s] %s (+%d/-%d)", icon, file.path, file.additions or 0, file.deletions or 0),
            path = file.path,
            idx = i,
        })
    end

    local title = state.is_local_review() and "Local Diff Files" or string.format("PR #%d Files", review.pr.number)

    telescope
        .new({}, {
            prompt_title = title,
            finder = finders.new_table({
                results = entries,
                entry_maker = function(entry)
                    return {
                        value = entry,
                        display = entry.display,
                        ordinal = entry.path,
                    }
                end,
            }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr)
                actions.select_default:replace(function()
                    actions.close(prompt_bufnr)
                    local selection = action_state.get_selected_entry()
                    if selection then
                        state.set_current_file_idx(selection.value.idx)
                        vim.cmd("edit " .. selection.value.path)
                    end
                end)
                return true
            end,
        })
        :find()
end

function M.show_file_picker_fallback()
    local state = require("greviewer.state")
    local review = state.get_review()

    if not review or not review.files then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local items = {}
    for i, file in ipairs(review.files) do
        table.insert(items, string.format("%d. [%s] %s", i, file.status, file.path))
    end

    vim.ui.select(items, { prompt = "Select file:" }, function(_, idx)
        if idx then
            state.set_current_file_idx(idx)
            vim.cmd("edit " .. review.files[idx].path)
        end
    end)
end

function M.next_hunk()
    local nav = require("greviewer.ui.nav")
    local config = require("greviewer.config")
    nav.next_hunk(config.values.wrap_navigation)
end

function M.prev_hunk()
    local nav = require("greviewer.ui.nav")
    local config = require("greviewer.config")
    nav.prev_hunk(config.values.wrap_navigation)
end

function M.next_comment()
    local nav = require("greviewer.ui.nav")
    local config = require("greviewer.config")
    nav.next_comment(config.values.wrap_navigation)
end

function M.prev_comment()
    local nav = require("greviewer.ui.nav")
    local config = require("greviewer.config")
    nav.prev_comment(config.values.wrap_navigation)
end

function M.toggle_prev_code()
    local virtual = require("greviewer.ui.virtual")
    virtual.toggle_at_cursor()
end

---@param opts? GReviewerAddCommentOpts
function M.add_comment(opts)
    local comments = require("greviewer.ui.comments")
    comments.add_at_cursor(opts)
end

function M.show_comment()
    local comments = require("greviewer.ui.comments")
    comments.show_thread()
end

function M.check_auth()
    local cli = require("greviewer.cli")
    cli.check_auth(function(ok, output)
        if ok then
            vim.notify(output, vim.log.levels.INFO)
        else
            vim.notify(output, vim.log.levels.ERROR)
        end
    end)
end

function M.approve()
    local state = require("greviewer.state")
    local cli = require("greviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    cli.submit_review(review.url, "APPROVE", nil, function(ok, err)
        if ok then
            vim.notify("Review approved", vim.log.levels.INFO)
        else
            vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end
    end)
end

---@param message? string
function M.request_changes(message)
    local state = require("greviewer.state")
    local cli = require("greviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local function submit_request(body)
        vim.notify("Submitting review...", vim.log.levels.INFO)
        cli.submit_review(review.url, "REQUEST_CHANGES", body, function(ok, err)
            if ok then
                vim.notify("Changes requested", vim.log.levels.INFO)
            else
                vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end)
    end

    if message and message ~= "" then
        submit_request(message)
    else
        local comments = require("greviewer.ui.comments")
        comments.open_multiline_input({ title = " Request Changes " }, submit_request)
    end
end

function M.done()
    local state = require("greviewer.state")
    local cli = require("greviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    local did_checkout = review.did_checkout
    local prev_branch = review.prev_branch
    local did_stash = review.did_stash

    state.clear_review()

    if did_checkout and prev_branch then
        vim.notify("Restoring previous branch...", vim.log.levels.INFO)
        cli.restore_branch(prev_branch, did_stash or false, function(ok, err)
            if ok then
                vim.notify(string.format("Restored to branch: %s", prev_branch), vim.log.levels.INFO)
            else
                vim.notify(err, vim.log.levels.ERROR)
            end
        end)
    else
        vim.notify("Review closed", vim.log.levels.INFO)
    end
end

return M
