---@class NRAddCommentOpts
---@field line1? integer Start line from visual selection
---@field line2? integer End line from visual selection

---@class NRReviewOpts
---@field analyze? boolean Whether to run AI analysis (nil = use config default)

---@class NRAskOpts
---@field prompt? string Prompt text (nil = request input)
---@field line1? integer Start line from visual selection
---@field line2? integer End line from visual selection
---@field range? integer Range count from user command

---@class NRModule
local M = {}

---@type "both"|"hidden"|nil
local stacked_feedback_anchor = nil

---@param input string
---@return boolean
local function is_github_url(input)
    return input:match("github%.com") ~= nil or input:match("^https?://") ~= nil
end

---@param review NRReview
---@return boolean
local function restore_previous_branch(review)
    if not review.did_checkout or not review.prev_branch then
        return false
    end

    local cli = require("neo_reviewer.cli")
    vim.notify("Restoring previous branch...", vim.log.levels.INFO)
    cli.restore_branch(review.prev_branch, function(ok, err)
        if ok then
            vim.notify(string.format("Restored to branch: %s", review.prev_branch), vim.log.levels.INFO)
        else
            vim.notify(err, vim.log.levels.ERROR)
        end
    end)

    return true
end

---@param opts? NRPartialConfig
function M.setup(opts)
    local config = require("neo_reviewer.config")
    config.setup(opts)

    if vim.fn.executable(config.values.cli_path) == 0 then
        vim.notify("neo-reviewer CLI not found. Please install it with: cargo install --path cli", vim.log.levels.WARN)
    end

    vim.api.nvim_create_user_command("ReviewPR", function(ctx)
        local args = ctx.args or ""
        local analyze = nil
        local url_or_number = nil

        for part in args:gmatch("%S+") do
            if part == "--analyze" then
                analyze = true
            elseif part == "--no-analyze" then
                analyze = false
            else
                url_or_number = part
            end
        end

        M.review_pr(url_or_number, { analyze = analyze })
    end, { nargs = "?", desc = "Open PR review" })

    vim.api.nvim_create_user_command("ReviewDiff", function(ctx)
        local args = ctx.args or ""
        local analyze = nil

        for part in args:gmatch("%S+") do
            if part == "--analyze" then
                analyze = true
            elseif part == "--no-analyze" then
                analyze = false
            end
        end

        M.review_diff({ analyze = analyze })
    end, { nargs = "?", desc = "Review local git diff (staged + unstaged changes)" })

    vim.api.nvim_create_user_command("Ask", function(ctx)
        M.ask({ line1 = ctx.line1, line2 = ctx.line2, range = ctx.range })
    end, { range = true, desc = "AI-guided codebase exploration" })

    vim.api.nvim_create_user_command("AddComment", function(ctx)
        M.add_comment({ line1 = ctx.line1, line2 = ctx.line2 })
    end, { range = true, desc = "Add comment at cursor or on visual selection" })

    vim.api.nvim_create_user_command("Approve", function()
        M.approve()
    end, { desc = "Approve the PR" })

    vim.api.nvim_create_user_command("RequestChanges", function(ctx)
        M.request_changes(ctx.args ~= "" and ctx.args or nil)
    end, { nargs = "?", desc = "Request changes on the PR" })

    vim.api.nvim_create_user_command("ReviewDone", function()
        M.done()
    end, { desc = "End review session without submitting" })

    vim.api.nvim_create_user_command("ReviewSync", function()
        M.sync()
    end, { desc = "Sync PR review with GitHub" })
end

---@param url_or_number? string|integer
---@param opts? NRReviewOpts
function M.review_pr(url_or_number, opts)
    local state = require("neo_reviewer.state")

    if state.get_review() then
        vim.notify(
            "A review is already active. Use :ReviewDone, :Approve, or :RequestChanges to end it first.",
            vim.log.levels.WARN
        )
        return
    end

    opts = opts or {}

    if url_or_number == nil then
        M.open(opts)
    elseif type(url_or_number) == "number" or tonumber(url_or_number) then
        local pr_number = tonumber(url_or_number) --[[@as integer]]
        M.open_with_checkout(pr_number, opts)
    else
        ---@cast url_or_number string
        if is_github_url(url_or_number) then
            M.open_url(url_or_number, opts)
        else
            M.open_with_branch(url_or_number, opts)
        end
    end
end

---@param opts? NRReviewOpts
function M.open(opts)
    local cli = require("neo_reviewer.cli")

    if cli.is_worktree_dirty() then
        vim.notify(
            "Warning: Uncommitted changes detected. Line numbers in the review may not match your local files.",
            vim.log.levels.WARN
        )
    end

    cli.get_pr_for_branch(function(pr_info, err)
        if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        local url = string.format("https://github.com/%s/%s/pull/%d", pr_info.owner, pr_info.repo, pr_info.number)
        vim.notify(string.format("Found PR #%d: %s", pr_info.number, pr_info.title), vim.log.levels.INFO)

        M.fetch_and_enable(url, nil, opts)
    end)
end

---@param pr_number integer
---@param opts? NRReviewOpts
function M.open_with_checkout(pr_number, opts)
    local cli = require("neo_reviewer.cli")
    local state = require("neo_reviewer.state")

    if cli.is_worktree_dirty() then
        vim.notify(
            "Cannot checkout PR: uncommitted changes in worktree. Commit or stash them first.",
            vim.log.levels.ERROR
        )
        return
    end

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
                state.set_checkout_state(checkout_info.prev_branch)
            end, opts)
        end)
    end)
end

---@param url string
---@param opts? NRReviewOpts
function M.open_url(url, opts)
    local cli = require("neo_reviewer.cli")
    local state = require("neo_reviewer.state")

    local parsed, parse_err = cli.parse_pr_url(url)
    if not parsed then
        vim.notify("Invalid PR URL: " .. (parse_err or "unknown error"), vim.log.levels.ERROR)
        return
    end

    local local_owner, local_repo = cli.get_git_remote()
    if not local_owner or not local_repo then
        vim.notify("Not in a git repository with a GitHub remote", vim.log.levels.ERROR)
        return
    end

    if local_owner ~= parsed.owner or local_repo ~= parsed.repo then
        vim.notify(
            string.format(
                "Repository mismatch: PR is from %s/%s but you're in %s/%s",
                parsed.owner,
                parsed.repo,
                local_owner,
                local_repo
            ),
            vim.log.levels.ERROR
        )
        return
    end

    if cli.is_worktree_dirty() then
        vim.notify(
            "Cannot checkout PR: uncommitted changes in worktree. Commit or stash them first.",
            vim.log.levels.ERROR
        )
        return
    end

    vim.notify(string.format("Checking out PR #%d...", parsed.number), vim.log.levels.INFO)

    cli.checkout_pr(url, function(checkout_info, err)
        if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end

        M.fetch_and_enable(url, function()
            state.set_checkout_state(checkout_info.prev_branch)
        end, opts)
    end)
end

---@param branch_name string
---@param opts? NRReviewOpts
function M.open_with_branch(branch_name, opts)
    local cli = require("neo_reviewer.cli")
    local state = require("neo_reviewer.state")

    if cli.is_worktree_dirty() then
        vim.notify(
            "Cannot checkout PR: uncommitted changes in worktree. Commit or stash them first.",
            vim.log.levels.ERROR
        )
        return
    end

    vim.notify(string.format("Checking out PR for branch '%s'...", branch_name), vim.log.levels.INFO)

    cli.checkout_pr(branch_name, function(checkout_info, err)
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
                state.set_checkout_state(checkout_info.prev_branch)
            end, opts)
        end)
    end)
end

---@param opts? NRReviewOpts
function M.review_diff(opts)
    local cli = require("neo_reviewer.cli")
    local state = require("neo_reviewer.state")
    local config = require("neo_reviewer.config")

    if state.get_review() then
        vim.notify(
            "A review is already active. Use :ReviewDone, :Approve, or :RequestChanges to end it first.",
            vim.log.levels.WARN
        )
        return
    end

    opts = opts or {}

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
        local review = state.set_local_review(data)

        local comments_file = require("neo_reviewer.ui.comments_file")
        comments_file.clear()

        local should_analyze = opts.analyze
        if should_analyze == nil then
            should_analyze = config.values.ai.enabled
        end

        local total_changes = 0
        for _, file in ipairs(data.files) do
            total_changes = total_changes + #(file.change_blocks or {})
        end

        local function finish_setup()
            M.enable_overlay()

            vim.notify(string.format("Local diff review enabled (%d files changed)", #data.files), vim.log.levels.INFO)

            local nav = require("neo_reviewer.ui.nav")
            nav.first_change()
        end

        if should_analyze then
            vim.notify(
                string.format(
                    "[neo-reviewer] Local diff fetched (%d files, %d changes). Running AI analysis...",
                    #data.files,
                    total_changes
                ),
                vim.log.levels.INFO
            )

            local ai = require("neo_reviewer.ai")
            ai.analyze_pr(review, function(analysis, ai_err)
                if ai_err then
                    vim.notify("[neo-reviewer] AI analysis failed: " .. ai_err, vim.log.levels.WARN)
                elseif analysis then
                    state.set_ai_analysis(analysis)
                    local ai_ui = require("neo_reviewer.ui.ai")
                    ai_ui.open()
                    vim.notify("[neo-reviewer] Analysis complete. Navigate with next/prev change", vim.log.levels.INFO)
                end

                finish_setup()
            end)
        else
            finish_setup()
        end
    end)
end

---@param url string
---@param on_ready? fun()
---@param opts? NRReviewOpts
function M.fetch_and_enable(url, on_ready, opts)
    local cli = require("neo_reviewer.cli")
    local state = require("neo_reviewer.state")
    local config = require("neo_reviewer.config")

    opts = opts or {}

    vim.notify("[neo-reviewer] Fetching PR...", vim.log.levels.INFO)

    cli.fetch_pr(url, function(data, err)
        if err then
            vim.notify("Failed to fetch PR: " .. err, vim.log.levels.ERROR)
            return
        end

        state.clear_review()
        local git_root = cli.get_git_root()
        local review = state.set_review(data, git_root)
        review.url = url

        if on_ready then
            on_ready()
        end

        local should_analyze = opts.analyze
        if should_analyze == nil then
            should_analyze = config.values.ai.enabled
        end

        local total_changes = 0
        for _, file in ipairs(data.files) do
            total_changes = total_changes + #(file.change_blocks or {})
        end

        local function finish_setup()
            M.enable_overlay()

            local nav = require("neo_reviewer.ui.nav")
            nav.first_change()
        end

        if should_analyze then
            vim.notify(
                string.format(
                    "[neo-reviewer] PR fetched (%d files, %d changes). Running AI analysis...",
                    #data.files,
                    total_changes
                ),
                vim.log.levels.INFO
            )

            local ai = require("neo_reviewer.ai")
            ai.analyze_pr(review, function(analysis, ai_err)
                if ai_err then
                    vim.notify("[neo-reviewer] AI analysis failed: " .. ai_err, vim.log.levels.WARN)
                elseif analysis then
                    state.set_ai_analysis(analysis)
                    local ai_ui = require("neo_reviewer.ui.ai")
                    ai_ui.open()
                    vim.notify("[neo-reviewer] Analysis complete. Navigate with next/prev change", vim.log.levels.INFO)
                end

                finish_setup()
            end)
        else
            vim.notify(
                string.format(
                    "[neo-reviewer] Review enabled for PR #%d: %s (%d files)",
                    data.pr.number,
                    data.pr.title,
                    #data.files
                ),
                vim.log.levels.INFO
            )

            finish_setup()
        end
    end)
end

function M.enable_overlay()
    local state = require("neo_reviewer.state")
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
    local state = require("neo_reviewer.state")
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

    local git_root = state.get_git_root()
    local relative_path = bufname
    if git_root and bufname:sub(1, #git_root) == git_root then
        relative_path = bufname:sub(#git_root + 2)
    end

    local file = state.get_file_by_path(relative_path)
    if not file then
        return
    end

    state.mark_buffer_applied(bufnr)

    vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
    if review.url then
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
    end

    local signs = require("neo_reviewer.ui.signs")
    signs.place(bufnr, file.change_blocks)

    if not state.is_local_review() then
        local comments_ui = require("neo_reviewer.ui.comments")
        comments_ui.show_existing(bufnr, file.path)
    end

    local buffer = require("neo_reviewer.ui.buffer")
    buffer.place_change_block_marks(bufnr, file)

    local config = require("neo_reviewer.config")
    local virtual = require("neo_reviewer.ui.virtual")
    if config.values.auto_expand_deletes or state.is_showing_old_code() then
        virtual.apply_mode_to_buffer(bufnr, file)
    end

    local ai_ui = require("neo_reviewer.ui.ai")
    ai_ui.apply(bufnr, file)
end

function M.show_file_picker()
    local state = require("neo_reviewer.state")
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
    local state = require("neo_reviewer.state")
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

function M.next_change()
    local nav = require("neo_reviewer.ui.nav")
    local config = require("neo_reviewer.config")
    local walkthrough_ui = require("neo_reviewer.ui.walkthrough")
    local state = require("neo_reviewer.state")
    if walkthrough_ui.is_open() and state.get_walkthrough() then
        walkthrough_ui.next_step(config.values.wrap_navigation)
        return
    end

    nav.next_change(config.values.wrap_navigation)
end

function M.prev_change()
    local nav = require("neo_reviewer.ui.nav")
    local config = require("neo_reviewer.config")
    local walkthrough_ui = require("neo_reviewer.ui.walkthrough")
    local state = require("neo_reviewer.state")
    if walkthrough_ui.is_open() and state.get_walkthrough() then
        walkthrough_ui.prev_step(config.values.wrap_navigation)
        return
    end

    nav.prev_change(config.values.wrap_navigation)
end

function M.next_comment()
    local nav = require("neo_reviewer.ui.nav")
    local config = require("neo_reviewer.config")
    nav.next_comment(config.values.wrap_navigation)
end

function M.prev_comment()
    local nav = require("neo_reviewer.ui.nav")
    local config = require("neo_reviewer.config")
    nav.prev_comment(config.values.wrap_navigation)
end

function M.toggle_prev_code()
    local virtual = require("neo_reviewer.ui.virtual")
    virtual.toggle_at_cursor()
end

---@param opts? NRAddCommentOpts
function M.add_comment(opts)
    local comments = require("neo_reviewer.ui.comments")
    comments.add_at_cursor(opts)
end

function M.show_comment()
    local comments = require("neo_reviewer.ui.comments")
    comments.show_thread()
end

function M.toggle_ai_feedback()
    local state = require("neo_reviewer.state")
    local walkthrough_ui = require("neo_reviewer.ui.walkthrough")
    local ai_ui = require("neo_reviewer.ui.ai")
    local review = state.get_review()
    local has_walkthrough = state.get_walkthrough() ~= nil
    local walkthrough_open = walkthrough_ui.is_open()
    local review_open = ai_ui.is_open()

    if review and has_walkthrough then
        if walkthrough_open and review_open then
            walkthrough_ui.close()
            stacked_feedback_anchor = "both"
            return
        end

        if review_open and not walkthrough_open then
            if stacked_feedback_anchor == "both" then
                ai_ui.close()
                stacked_feedback_anchor = "hidden"
            else
                walkthrough_ui.open()
                stacked_feedback_anchor = "both"
            end
            return
        end

        if not review_open and not walkthrough_open then
            ai_ui.open()
            stacked_feedback_anchor = "hidden"
            return
        end

        if walkthrough_open and not review_open then
            walkthrough_ui.close()
            stacked_feedback_anchor = "hidden"
            return
        end
    end

    stacked_feedback_anchor = nil

    if has_walkthrough or walkthrough_open then
        walkthrough_ui.toggle()
        return
    end

    ai_ui.show_details()
end

---@param path string
---@return boolean
local function is_absolute_path(path)
    return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil
end

---@param path string
---@param root string|nil
---@return string
local function to_repo_relative(path, root)
    if not root or root == "" then
        return path
    end

    local trimmed = root:gsub("/+$", "")
    if is_absolute_path(path) and path:sub(1, #trimmed + 1) == trimmed .. "/" then
        return path:sub(#trimmed + 2)
    end

    return path
end

---@param opts? NRAskOpts
---@return string|nil
---@return integer|nil
---@return integer|nil
---@return string|nil
---@return string
local function collect_ask_seed(opts)
    local cli = require("neo_reviewer.cli")
    local root = cli.get_git_root() or vim.fn.getcwd()
    local bufnr = vim.api.nvim_get_current_buf()

    local seed_file = nil
    local seed_start = nil
    local seed_end = nil
    local seed_snippet = nil

    if vim.bo[bufnr].buftype == "" then
        local path = vim.api.nvim_buf_get_name(bufnr)
        if path ~= "" then
            seed_file = to_repo_relative(path, root)
        end
    end

    if seed_file and opts and opts.range and opts.range > 0 and opts.line1 and opts.line2 then
        local line1 = opts.line1 --[[@as integer]]
        local line2 = opts.line2 --[[@as integer]]
        local start_line = math.min(line1, line2)
        local end_line = math.max(line1, line2)
        local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
        seed_snippet = table.concat(lines, "\n")
        seed_start = start_line
        seed_end = end_line
    end

    return seed_file, seed_start, seed_end, seed_snippet, root
end

---@param opts? NRAskOpts
---@return nil
function M.ask(opts)
    opts = opts or {}
    local comments = require("neo_reviewer.ui.comments")
    local state = require("neo_reviewer.state")
    local walkthrough_ui = require("neo_reviewer.ui.walkthrough")
    local walkthrough = require("neo_reviewer.walkthrough")

    ---@param prompt string
    ---@return nil
    local function run_with_prompt(prompt)
        local seed_file, seed_start, seed_end, seed_snippet, root = collect_ask_seed(opts)

        walkthrough_ui.close()
        state.clear_walkthrough()
        walkthrough_ui.show_loading()

        walkthrough.run({
            prompt = prompt,
            root = root,
            seed_file = seed_file,
            seed_start_line = seed_start,
            seed_end_line = seed_end,
            seed_snippet = seed_snippet,
        }, function(result, err)
            if err then
                walkthrough_ui.close()
                vim.notify("[neo-reviewer] Ask failed: " .. err, vim.log.levels.WARN)
                return
            end
            if not result then
                walkthrough_ui.close()
                vim.notify("[neo-reviewer] Ask failed: unknown error", vim.log.levels.WARN)
                return
            end

            state.set_walkthrough(result)
            walkthrough_ui.open({ jump_to_first = true })
        end)
    end

    if opts.prompt and opts.prompt ~= "" then
        run_with_prompt(opts.prompt)
        return
    end

    comments.open_multiline_input({ title = " Ask " }, function(body)
        run_with_prompt(body)
    end)
end

function M.check_auth()
    local cli = require("neo_reviewer.cli")
    cli.check_auth(function(ok, output)
        if ok then
            vim.notify(output, vim.log.levels.INFO)
        else
            vim.notify(output, vim.log.levels.ERROR)
        end
    end)
end

function M.approve()
    local state = require("neo_reviewer.state")
    local cli = require("neo_reviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    if state.is_local_review() then
        vim.notify("Cannot approve a local diff review", vim.log.levels.WARN)
        return
    end

    if review.viewer and review.pr and review.viewer == review.pr.author then
        vim.notify("Cannot approve your own pull request", vim.log.levels.WARN)
        return
    end

    cli.submit_review(review.url, "APPROVE", nil, function(ok, err)
        if ok then
            state.clear_review()
            vim.notify("Review approved", vim.log.levels.INFO)
            restore_previous_branch(review)
        else
            vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end
    end)
end

---@param message? string
function M.request_changes(message)
    local state = require("neo_reviewer.state")
    local cli = require("neo_reviewer.cli")
    local review = state.get_review()

    if not review then
        vim.notify("No active review", vim.log.levels.WARN)
        return
    end

    if state.is_local_review() then
        vim.notify("Cannot request changes on a local diff review", vim.log.levels.WARN)
        return
    end

    if review.viewer and review.pr and review.viewer == review.pr.author then
        vim.notify("Cannot request changes on your own pull request", vim.log.levels.WARN)
        return
    end

    local function submit_request(body)
        vim.notify("Submitting review...", vim.log.levels.INFO)
        cli.submit_review(review.url, "REQUEST_CHANGES", body, function(ok, err)
            if ok then
                state.clear_review()
                vim.notify("Changes requested", vim.log.levels.INFO)
                restore_previous_branch(review)
            else
                vim.notify("Failed to submit review: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end)
    end

    if message and message ~= "" then
        submit_request(message)
    else
        local comments = require("neo_reviewer.ui.comments")
        comments.open_multiline_input({ title = " Request Changes " }, submit_request)
    end
end

function M.done()
    local state = require("neo_reviewer.state")
    local review = state.get_review()
    stacked_feedback_anchor = nil
    local walkthrough_ui = require("neo_reviewer.ui.walkthrough")
    local has_walkthrough = state.get_walkthrough() ~= nil
    local closed_window = walkthrough_ui.close()
    if has_walkthrough then
        state.clear_walkthrough()
    end

    if review then
        state.clear_review()

        if not restore_previous_branch(review) then
            vim.notify("Review closed", vim.log.levels.INFO)
        end
        return
    end

    if has_walkthrough then
        vim.notify("Walkthrough closed", vim.log.levels.INFO)
        return
    end

    if closed_window then
        vim.notify("Walkthrough window closed", vim.log.levels.INFO)
        return
    end

    vim.notify("No active review", vim.log.levels.WARN)
end

function M.sync()
    local state = require("neo_reviewer.state")
    local cli = require("neo_reviewer.cli")
    local signs = require("neo_reviewer.ui.signs")
    local virtual = require("neo_reviewer.ui.virtual")
    local comments_ui = require("neo_reviewer.ui.comments")

    local review = state.get_review()
    if not review then
        vim.notify("No active review to sync", vim.log.levels.WARN)
        return
    end

    if review.review_type ~= "pr" or not review.url then
        vim.notify("Sync only works for PR reviews", vim.log.levels.WARN)
        return
    end

    local preserved = {
        url = review.url,
        git_root = review.git_root,
        expanded_changes = review.expanded_changes,
        did_checkout = review.did_checkout,
        prev_branch = review.prev_branch,
    }
    local old_comment_count = #review.comments
    local cursor_pos = vim.api.nvim_win_get_cursor(0)

    vim.notify("Syncing PR data...", vim.log.levels.INFO)

    cli.fetch_pr(preserved.url, function(data, err)
        if err then
            vim.notify("Failed to sync PR: " .. err, vim.log.levels.ERROR)
            return
        end

        for bufnr, _ in pairs(review.applied_buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                signs.clear(bufnr)
                virtual.clear(bufnr)
                comments_ui.clear(bufnr)
            end
        end

        if review.autocmd_id then
            vim.api.nvim_del_autocmd(review.autocmd_id)
        end

        state.set_review(data, preserved.git_root)
        local new_review = state.get_review()
        if not new_review then
            vim.notify("Failed to sync: review state lost", vim.log.levels.ERROR)
            return
        end

        new_review.url = preserved.url
        new_review.expanded_changes = preserved.expanded_changes
        new_review.did_checkout = preserved.did_checkout
        new_review.prev_branch = preserved.prev_branch

        M.enable_overlay()

        pcall(vim.api.nvim_win_set_cursor, 0, cursor_pos)

        local new_comment_count = #(new_review.comments or {})
        local diff = new_comment_count - old_comment_count
        if diff > 0 then
            vim.notify(string.format("Synced: %d new comment%s", diff, diff == 1 and "" or "s"), vim.log.levels.INFO)
        else
            vim.notify("Synced: no new comments", vim.log.levels.INFO)
        end
    end)
end

return M
