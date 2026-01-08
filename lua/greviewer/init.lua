local M = {}

function M.setup(opts)
    local config = require("greviewer.config")
    config.setup(opts)

    if vim.fn.executable(config.values.cli_path) == 0 then
        vim.notify(
            "greviewer-cli not found. Please install it with: cargo install --path cli",
            vim.log.levels.WARN
        )
    end

    vim.api.nvim_create_user_command("GReview", function(ctx)
        local arg = ctx.args
        local state = require("greviewer.state")

        if arg and arg ~= "" then
            local pr_number = tonumber(arg)
            if pr_number then
                M.open_with_checkout(pr_number)
            else
                M.open_url(arg)
            end
        elseif state.get_review() then
            M.toggle_overlays()
        else
            M.open()
        end
    end, { nargs = "?", desc = "Open PR review, or toggle overlays if review is active" })

    vim.api.nvim_create_user_command("GReviewDone", function()
        M.done()
    end, { desc = "Close review and restore previous state" })

    vim.api.nvim_create_user_command("GReviewFiles", function()
        M.show_file_picker()
    end, { desc = "Show changed files picker" })

    vim.api.nvim_create_user_command("GReviewAuth", function()
        M.check_auth()
    end, { desc = "Check GitHub authentication" })

    vim.api.nvim_create_user_command("GReviewSubmit", function()
        M.submit_review()
    end, { desc = "Submit review (approve or request changes)" })
end

function M.open()
    local cli = require("greviewer.cli")
    local state = require("greviewer.state")

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

function M.open_url(url)
    M.fetch_and_enable(url)
end

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
            string.format("Review mode enabled for PR #%d: %s (%d files changed)", data.pr.number, data.pr.title, #data.files),
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
    vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", review.url)

    local signs = require("greviewer.ui.signs")
    signs.place(bufnr, file.hunks)

    local comments_ui = require("greviewer.ui.comments")
    comments_ui.show_existing(bufnr, file.path)
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
        cli.restore_branch(prev_branch, did_stash, function(ok, err)
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

    local entries = {}
    for i, file in ipairs(review.files) do
        local icon = ({ add = "+", delete = "-", modified = "~", renamed = "R" })[file.status] or "?"
        table.insert(entries, {
            display = string.format("[%s] %s (+%d/-%d)", icon, file.path, file.additions or 0, file.deletions or 0),
            path = file.path,
            idx = i,
        })
    end

    telescope.new({}, {
        prompt_title = string.format("PR #%d Files", review.pr.number),
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
    }):find()
end

function M.show_file_picker_fallback()
    local state = require("greviewer.state")
    local review = state.get_review()

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

function M.toggle_inline()
    local virtual = require("greviewer.ui.virtual")
    virtual.toggle_at_cursor()
end

function M.add_comment()
    local comments = require("greviewer.ui.comments")
    comments.add_at_cursor()
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

function M.submit_review()
    local state = require("greviewer.state")
    local cli = require("greviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    vim.ui.select({ "Approve", "Request Changes" }, {
        prompt = "Submit review:",
    }, function(choice)
        if not choice then
            return
        end

        if choice == "Approve" then
            cli.submit_review(review.url, "APPROVE", nil, function(ok, err)
                if ok then
                    vim.notify("Review approved", vim.log.levels.INFO)
                else
                    vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
                end
            end)
        else
            vim.ui.input({
                prompt = "Message (leave empty for default): ",
            }, function(input)
                local body = input
                if not body or body == "" then
                    body = "Please see inline comments"
                end
                cli.submit_review(review.url, "REQUEST_CHANGES", body, function(ok, err)
                    if ok then
                        vim.notify("Changes requested", vim.log.levels.INFO)
                    else
                        vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
                    end
                end)
            end)
        end
    end)
end

function M.show_overlays()
    local state = require("greviewer.state")
    if not state.get_review() then
        return
    end

    M.enable_overlay()
    state.set_overlays_visible(true)
end

function M.toggle_overlays()
    local state = require("greviewer.state")
    local review = state.get_review()
    if not review then
        return false
    end

    if state.are_overlays_visible() then
        state.hide_overlays()
        vim.notify("Review overlays hidden", vim.log.levels.INFO)
    else
        M.show_overlays()
        vim.notify("Review overlays shown", vim.log.levels.INFO)
    end
    return true
end

return M
