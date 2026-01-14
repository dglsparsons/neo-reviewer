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
        stub(cli, "get_git_remote")

        neo_reviewer = require("neo_reviewer")
        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        cli.fetch_pr:revert()
        cli.checkout_pr:revert()
        cli.get_pr_for_branch:revert()
        cli.is_worktree_dirty:revert()
        cli.get_git_remote:revert()

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
                assert.is_nil(n.msg:match("Uncommitted changes detected"))
            end
        end)

        it("calls get_pr_for_branch to find PR", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open()

            assert.stub(cli.get_pr_for_branch).was_called(1)
        end)
    end)

    describe("open_url", function()
        it("errors when repo does not match URL", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("different-owner", "different-repo")

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_not_called()
            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Repository mismatch") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error about repository mismatch")
        end)

        it("includes repo names in mismatch error message", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("local-owner", "local-repo")

            neo_reviewer.open_url("https://github.com/pr-owner/pr-repo/pull/123")

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if
                    n.msg:match("pr%-owner/pr%-repo")
                    and n.msg:match("local%-owner/local%-repo")
                    and n.level == vim.log.levels.ERROR
                then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error message to include both repo names")
        end)

        it("errors when not in a git repository", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns(nil, nil)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_not_called()
            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Not in a git repository") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error about not being in a git repository")
        end)

        it("errors when URL is invalid", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")

            neo_reviewer.open_url("not-a-valid-url")

            assert.stub(cli.checkout_pr).was_not_called()
            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Invalid PR URL") and n.level == vim.log.levels.ERROR then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected error about invalid PR URL")
        end)

        it("errors when worktree is dirty", function()
            cli.is_worktree_dirty.returns(true)
            cli.get_git_remote.returns("owner", "repo")

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

        it("calls checkout_pr with the URL when repo matches", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("notifies user about checkout in progress with PR number", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Checking out PR #123") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected 'Checking out PR #123...' notification")
        end)

        it("calls fetch_and_enable after successful checkout", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")
            cli.checkout_pr.invokes(function(_, callback)
                callback({ prev_branch = "main" }, nil)
            end)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.fetch_pr).was_called(1)
            assert.stub(cli.fetch_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("does not fetch on checkout failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")
            cli.checkout_pr.invokes(function(_, callback)
                callback(nil, "Failed to checkout")
            end)

            neo_reviewer.open_url("https://github.com/owner/repo/pull/123")

            assert.stub(cli.fetch_pr).was_not_called()
        end)

        it("shows error notification on checkout failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")
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

    describe("open_with_branch", function()
        it("errors when worktree is dirty", function()
            cli.is_worktree_dirty.returns(true)

            neo_reviewer.open_with_branch("feature/my-branch")

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

        it("calls checkout_pr with branch name when clean", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open_with_branch("feature/my-branch")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("feature/my-branch", match._)
        end)

        it("notifies user about checkout with branch name", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.open_with_branch("feature/my-branch")

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Checking out PR for branch 'feature/my%-branch'") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected notification with branch name")
        end)

        it("calls get_pr_for_branch after successful checkout", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback({ prev_branch = "main" }, nil)
            end)

            neo_reviewer.open_with_branch("feature/my-branch")

            assert.stub(cli.get_pr_for_branch).was_called(1)
        end)

        it("fetches PR after getting branch info", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback({ prev_branch = "main" }, nil)
            end)
            cli.get_pr_for_branch.invokes(function(callback)
                callback({
                    number = 456,
                    title = "Test PR",
                    owner = "owner",
                    repo = "repo",
                }, nil)
            end)

            neo_reviewer.open_with_branch("feature/my-branch")

            assert.stub(cli.fetch_pr).was_called(1)
            assert.stub(cli.fetch_pr).was_called_with("https://github.com/owner/repo/pull/456", match._)
        end)

        it("does not fetch on checkout failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback(nil, "Failed to checkout")
            end)

            neo_reviewer.open_with_branch("feature/my-branch")

            assert.stub(cli.get_pr_for_branch).was_not_called()
            assert.stub(cli.fetch_pr).was_not_called()
        end)

        it("does not fetch on get_pr_for_branch failure", function()
            cli.is_worktree_dirty.returns(false)
            cli.checkout_pr.invokes(function(_, callback)
                callback({ prev_branch = "main" }, nil)
            end)
            cli.get_pr_for_branch.invokes(function(callback)
                callback(nil, "No PR found for branch")
            end)

            neo_reviewer.open_with_branch("feature/my-branch")

            assert.stub(cli.fetch_pr).was_not_called()
        end)
    end)

    describe("review_pr routing", function()
        it("routes to open when no argument", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.review_pr(nil)

            assert.stub(cli.get_pr_for_branch).was_called(1)
            assert.stub(cli.checkout_pr).was_not_called()
        end)

        it("routes to open_with_checkout for numeric string", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.review_pr("123")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with(123, match._)
        end)

        it("routes to open_url for github URL", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")

            neo_reviewer.review_pr("https://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("routes to open_with_branch for non-URL string", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.review_pr("feature/my-branch")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("feature/my-branch", match._)
        end)

        it("routes to open_with_branch for branch names with slashes", function()
            cli.is_worktree_dirty.returns(false)

            neo_reviewer.review_pr("user/feature/add-tests")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("user/feature/add-tests", match._)
        end)

        it("routes to open_url for URL starting with http", function()
            cli.is_worktree_dirty.returns(false)
            cli.get_git_remote.returns("owner", "repo")

            neo_reviewer.review_pr("http://github.com/owner/repo/pull/123")

            assert.stub(cli.checkout_pr).was_called(1)
            assert.stub(cli.checkout_pr).was_called_with("http://github.com/owner/repo/pull/123", match._)
        end)
    end)
end)
