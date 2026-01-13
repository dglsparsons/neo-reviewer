local stub = require("luassert.stub")
local match = require("luassert.match")
local helpers = require("plenary.helpers")

describe("neo_reviewer review opening", function()
    local neo_reviewer
    local state
    local cli
    local notifications

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.cli"] = nil

        state = require("neo_reviewer.state")
        cli = require("neo_reviewer.cli")

        stub(cli, "fetch_pr")
        stub(cli, "checkout_pr")
        stub(cli, "get_pr_for_branch")
        stub(cli, "is_worktree_dirty")

        neo_reviewer = require("neo_reviewer")
        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        cli.fetch_pr:revert()
        cli.checkout_pr:revert()
        cli.get_pr_for_branch:revert()
        cli.is_worktree_dirty:revert()

        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    describe("open (no args - current branch)", function()
        it("warns when worktree is dirty", function()
            cli.is_worktree_dirty.returns(true)

            neo_reviewer.open()

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Uncommitted changes detected") and n.level == vim.log.levels.WARN then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected warning about uncommitted changes")
        end)

        it("does not warn when worktree is clean", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open()

            local notifs = notifications.get()
            for _, n in ipairs(notifs) do
                assert.is_not.matches("Uncommitted changes detected", n.msg)
            end
        end)

        it("calls get_pr_for_branch to find PR", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open()

            assert.stub(cli.get_pr_for_branch).was_called(1)
        end)
    end)

    describe("open_url", function()
        it("errors when worktree is dirty", function()
            cli.is_worktree_dirty.returns(true)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_not_called()
            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Cannot checkout PR") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error about uncommitted changes")
        end)

        it("calls checkout_pr with the URL when clean", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("notifies user about checkout in progress", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Checking out PR") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected 'Checking out PR...' notification")
        end)

        it("calls fetch_and_enable after successful checkout", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback({ prev_branch = "main" }, nil)
            end)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.fetch_pr).was_called(1)
            assert.stub(cli.fetch_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("does not fetch on checkout failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback(nil, "Failed to checkout")
            end)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.fetch_pr).was_not_called()
        end)

        it("shows error notification on checkout failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                vim.schedule(function()
                    callback(nil, "Failed to checkout PR")
                end)
            end)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            vim.wait(100, function()
                local notifs = notifications.get()
                for _, n in ipairs(notifs) do
                    if n.msg:match("Failed to checkout PR") then
                        return true
                    end
                end
                return false
            end)

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Failed to checkout PR") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error notification about checkout failure")
        end)
    end)

    describe("open_with_checkout", function()
        it("errors when worktree is dirty", function()
            cli.is_worktree_dirty.returns(true)

            neo_reviewer.open_with_checkout(123)

            assert.stub(cli.checkout_pr).was_not_called()
            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Cannot checkout PR") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error about uncommitted changes")
        end)

        it("calls checkout_pr with PR number when clean", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open_with_checkout(123)

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with(123, match._)
        end)
    end)
end)
