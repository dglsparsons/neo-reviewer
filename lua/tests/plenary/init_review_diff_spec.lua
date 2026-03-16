local stub = require("luassert.stub")
local helpers = require("plenary.helpers")

describe("neo_reviewer review noise filtering", function()
    local neo_reviewer
    local state
    local cli
    local config
    local nav
    local notifications

    ---@return integer|nil
    local function find_loading_buffer()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == "neo-reviewer-loading" and vim.fn.bufwinid(buf) ~= -1 then
                return buf
            end
        end
        return nil
    end

    ---@param files table[]
    ---@return table
    local function pr_data(files)
        return {
            pr = {
                number = 123,
                title = "Test PR",
                description = "Testing",
            },
            files = files,
            comments = {},
        }
    end

    ---@param pattern string
    ---@param level? integer
    ---@return boolean
    local function has_notification(pattern, level)
        for _, n in ipairs(notifications.get()) do
            if n.msg:match(pattern) and (level == nil or n.level == level) then
                return true
            end
        end
        return false
    end

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.cli"] = nil
        package.loaded["neo_reviewer.config"] = nil
        package.loaded["neo_reviewer.ai"] = nil
        package.loaded["neo_reviewer.ui.ai"] = nil
        package.loaded["neo_reviewer.ui.nav"] = nil
        package.loaded["neo_reviewer.ui.comments"] = nil
        state = require("neo_reviewer.state")
        cli = require("neo_reviewer.cli")
        config = require("neo_reviewer.config")
        neo_reviewer = require("neo_reviewer")
        nav = require("neo_reviewer.ui.nav")

        stub(neo_reviewer, "enable_overlay")
        stub(nav, "first_change")

        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        neo_reviewer.enable_overlay:revert()
        nav.first_change:revert()

        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("skips default noise files in local diff reviews", function()
        cli.get_local_diff = function(_, callback)
            callback({
                git_root = "/tmp/test-repo",
                files = {
                    { path = "src/main.lua", status = "modified", change_blocks = {} },
                    { path = "pnpm-lock.yaml", status = "modified", change_blocks = {} },
                    { path = "nested/Cargo.lock", status = "modified", change_blocks = {} },
                },
            }, nil)
        end

        neo_reviewer.review_diff({ analyze = false })

        local review = state.get_review()
        assert.is_not_nil(review)
        assert.are.equal(1, #review.files)
        assert.are.equal("src/main.lua", review.files[1].path)
        assert.is_true(has_notification("Skipped 2 noise file%(s%)", vim.log.levels.INFO))
    end)

    it("warns and aborts when all changed files are noise files", function()
        cli.get_local_diff = function(_, callback)
            callback({
                git_root = "/tmp/test-repo",
                files = {
                    { path = "pnpm-lock.yaml", status = "modified", change_blocks = {} },
                    { path = "Cargo.lock", status = "modified", change_blocks = {} },
                },
            }, nil)
        end

        neo_reviewer.review_diff({ analyze = false })

        assert.is_nil(state.get_review())
        assert.is_true(has_notification("No reviewable changes after skipping 2 noise files", vim.log.levels.WARN))
        assert.stub(neo_reviewer.enable_overlay).was_not_called()
    end)

    it("runs AI analysis using the filtered local diff files", function()
        cli.get_local_diff = function(_, callback)
            callback({
                git_root = "/tmp/test-repo",
                files = {
                    { path = "src/main.lua", status = "modified", change_blocks = {} },
                    { path = "Cargo.lock", status = "modified", change_blocks = {} },
                },
            }, nil)
        end

        local analyzed_review
        local ai = require("neo_reviewer.ai")
        ai.analyze_pr = function(review, callback)
            analyzed_review = review
            callback({ overview = "ok", steps = {} }, nil)
        end

        local ai_ui = require("neo_reviewer.ui.ai")
        ai_ui.open = function() end

        config.setup({ ai = { enabled = true } })

        neo_reviewer.review_diff({ analyze = true })

        assert.is_not_nil(analyzed_review)
        assert.are.equal(1, #analyzed_review.files)
        assert.are.equal("src/main.lua", analyzed_review.files[1].path)
    end)

    it("shows a loading scratch buffer while local diff analysis is running", function()
        cli.get_local_diff = function(_, callback)
            callback({
                git_root = "/tmp/test-repo",
                files = {
                    {
                        path = "src/main.lua",
                        status = "modified",
                        change_blocks = { { start_line = 1, end_line = 1 } },
                    },
                },
            }, nil)
        end

        local pending_callback
        local ai = require("neo_reviewer.ai")
        ai.analyze_pr = function(_, callback)
            pending_callback = callback
        end

        local opened = 0
        local ai_ui = require("neo_reviewer.ui.ai")
        ai_ui.open = function()
            opened = opened + 1
        end

        package.preload["neo_reviewer.ui.loading"] = nil
        package.loaded["neo_reviewer.ui.loading"] = nil
        package.loaded["neo_reviewer.plugin"] = {
            register_preloads = function() end,
        }

        config.setup({ ai = { enabled = true } })

        neo_reviewer.review_diff({ analyze = true })

        local loading_bufnr = assert(find_loading_buffer())
        local rendered = table.concat(vim.api.nvim_buf_get_lines(loading_bufnr, 0, -1, false), "\n")
        assert.is_truthy(rendered:find("Review: generating walkthrough", 1, true))
        assert.is_truthy(rendered:find("Analyzing 1 file and 1 change with AI", 1, true))
        assert.is_not_nil(pending_callback)
        assert.are.equal(0, opened)

        pending_callback({ overview = "ok", steps = {} }, nil)

        assert.are.equal(1, opened)
        assert.is_nil(find_loading_buffer())
    end)

    it("re-renders local comments when a reviewed file buffer is reopened", function()
        local repo_root = vim.fn.tempname()
        vim.fn.mkdir(repo_root .. "/src", "p")
        vim.fn.writefile({ "line 1", "line 2", "line 3" }, repo_root .. "/src/main.lua")
        vim.fn.writefile({ "line 1", "line 2" }, repo_root .. "/src/other.lua")

        state.set_local_review({
            git_root = repo_root,
            files = {
                {
                    path = "src/main.lua",
                    status = "modified",
                    change_blocks = {},
                },
                {
                    path = "src/other.lua",
                    status = "modified",
                    change_blocks = {},
                },
            },
        })

        state.add_comment({
            id = 7,
            path = "src/main.lua",
            line = 2,
            side = "RIGHT",
            body = "keep this comment",
            author = "you",
            created_at = "2025-01-01T00:00:00Z",
        })

        vim.cmd("edit " .. vim.fn.fnameescape(repo_root .. "/src/main.lua"))
        local first_main = vim.api.nvim_get_current_buf()
        neo_reviewer.apply_overlay_to_buffer(first_main)
        assert.is_true(#helpers.get_extmarks(first_main, "nr_comments") > 0)

        vim.cmd("edit " .. vim.fn.fnameescape(repo_root .. "/src/other.lua"))
        local other = vim.api.nvim_get_current_buf()
        neo_reviewer.apply_overlay_to_buffer(other)

        vim.api.nvim_buf_delete(first_main, { force = true })

        vim.cmd("edit " .. vim.fn.fnameescape(repo_root .. "/src/main.lua"))
        local reopened_main = vim.api.nvim_get_current_buf()
        neo_reviewer.apply_overlay_to_buffer(reopened_main)

        local extmarks = helpers.get_extmarks(reopened_main, "nr_comments")
        assert.is_true(#extmarks > 0)
    end)

    it("skips default noise files in PR reviews", function()
        cli.fetch_pr = function(_, callback)
            callback(
                pr_data({
                    { path = "src/main.lua", status = "modified", change_blocks = {} },
                    { path = "pnpm-lock.yaml", status = "modified", change_blocks = {} },
                    { path = "nested/Cargo.lock", status = "modified", change_blocks = {} },
                }),
                nil
            )
        end
        cli.get_git_root = function()
            return "/tmp/test-repo"
        end

        neo_reviewer.fetch_and_enable("https://github.com/owner/repo/pull/123", nil, { analyze = false })

        local review = state.get_review()
        assert.is_not_nil(review)
        assert.are.equal(1, #review.files)
        assert.are.equal("src/main.lua", review.files[1].path)
        assert.is_true(has_notification("Skipped 2 noise file%(s%) in PR review", vim.log.levels.INFO))
    end)

    it("warns and aborts when all PR files are noise files", function()
        cli.fetch_pr = function(_, callback)
            callback(
                pr_data({
                    { path = "pnpm-lock.yaml", status = "modified", change_blocks = {} },
                    { path = "Cargo.lock", status = "modified", change_blocks = {} },
                }),
                nil
            )
        end
        cli.get_git_root = function()
            return "/tmp/test-repo"
        end

        neo_reviewer.fetch_and_enable("https://github.com/owner/repo/pull/123", nil, { analyze = false })

        assert.is_nil(state.get_review())
        assert.is_true(has_notification("No reviewable changes after skipping 2 noise files", vim.log.levels.WARN))
        assert.stub(neo_reviewer.enable_overlay).was_not_called()
    end)

    it("runs AI analysis using the filtered PR files", function()
        cli.fetch_pr = function(_, callback)
            callback(
                pr_data({
                    { path = "src/main.lua", status = "modified", change_blocks = {} },
                    { path = "Cargo.lock", status = "modified", change_blocks = {} },
                }),
                nil
            )
        end
        cli.get_git_root = function()
            return "/tmp/test-repo"
        end

        local analyzed_review
        local ai = require("neo_reviewer.ai")
        ai.analyze_pr = function(review, callback)
            analyzed_review = review
            callback({ overview = "ok", steps = {} }, nil)
        end

        local ai_ui = require("neo_reviewer.ui.ai")
        ai_ui.open = function() end

        config.setup({ ai = { enabled = true } })

        neo_reviewer.fetch_and_enable("https://github.com/owner/repo/pull/123", nil, { analyze = true })

        assert.is_not_nil(analyzed_review)
        assert.are.equal(1, #analyzed_review.files)
        assert.are.equal("src/main.lua", analyzed_review.files[1].path)
    end)

    it("shows a loading scratch buffer while PR analysis is running", function()
        cli.fetch_pr = function(_, callback)
            callback(
                pr_data({
                    {
                        path = "src/main.lua",
                        status = "modified",
                        change_blocks = { { start_line = 1, end_line = 1 } },
                    },
                }),
                nil
            )
        end
        cli.get_git_root = function()
            return "/tmp/test-repo"
        end

        local pending_callback
        local ai = require("neo_reviewer.ai")
        ai.analyze_pr = function(_, callback)
            pending_callback = callback
        end

        local opened = 0
        local ai_ui = require("neo_reviewer.ui.ai")
        ai_ui.open = function()
            opened = opened + 1
        end

        config.setup({ ai = { enabled = true } })

        neo_reviewer.fetch_and_enable("https://github.com/owner/repo/pull/123", nil, { analyze = true })

        local loading_bufnr = assert(find_loading_buffer())
        local rendered = table.concat(vim.api.nvim_buf_get_lines(loading_bufnr, 0, -1, false), "\n")
        assert.is_truthy(rendered:find("Review: generating walkthrough", 1, true))
        assert.is_truthy(rendered:find("Analyzing 1 file and 1 change with AI", 1, true))
        assert.is_not_nil(pending_callback)
        assert.are.equal(0, opened)

        pending_callback({ overview = "ok", steps = {} }, nil)

        assert.are.equal(1, opened)
        assert.is_nil(find_loading_buffer())
    end)

    it("passes diff selection options to the CLI", function()
        local received_opts

        cli.get_local_diff = function(opts, callback)
            received_opts = opts
            callback({
                git_root = "/tmp/test-repo",
                files = {
                    { path = "src/main.lua", status = "modified", change_blocks = {} },
                },
            }, nil)
        end

        neo_reviewer.review_diff({
            analyze = false,
            target = "main",
            cached_only = true,
            merge_base = true,
            tracked_only = true,
        })

        assert.are.same({
            target = "main",
            cached_only = true,
            merge_base = true,
            tracked_only = true,
        }, received_opts)
    end)

    it("rejects invalid option combinations passed via Lua API", function()
        neo_reviewer.review_diff({ uncached_only = true, target = "main" })

        assert.is_true(
            has_notification(
                "Cannot use a revision target with %-%-uncached%-only for :ReviewDiff",
                vim.log.levels.ERROR
            )
        )
        assert.is_nil(state.get_review())
    end)
end)
