local stub = require("luassert.stub")
local match = require("luassert.match")
local helpers = require("plenary.helpers")
local mock_data = require("fixtures.mock_pr_data")

describe("neo_reviewer.sync", function()
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
        stub(cli, "get_local_diff")

        neo_reviewer = require("neo_reviewer")

        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        cli.fetch_pr:revert()
        cli.get_local_diff:revert()

        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    describe("sync", function()
        it("warns when no active review", function()
            neo_reviewer.sync()

            local notifs = notifications.get()
            assert.are.equal(1, #notifs)
            assert.matches("No active review to sync", notifs[1].msg)
            assert.are.equal(vim.log.levels.WARN, notifs[1].level)
        end)

        it("syncs local diff review by re-running diff with saved options", function()
            state.set_local_review(mock_data.local_diff, {
                target = "main",
                tracked_only = true,
            })

            cli.get_local_diff.invokes(function(_, callback)
                callback({
                    git_root = "/tmp/test",
                    files = {
                        { path = "src/synced.lua", status = "modified", change_blocks = {} },
                    },
                }, nil)
            end)

            neo_reviewer.sync()

            assert.stub(cli.get_local_diff).was_called(1)
            assert.stub(cli.get_local_diff).was_called_with({
                target = "main",
                tracked_only = true,
            }, match._)

            local review = state.get_review()
            assert.is_not_nil(review)
            assert.are.equal("local", review.review_type)
            assert.are.equal(1, #review.files)
            assert.are.equal("src/synced.lua", review.files[1].path)
        end)

        it("clears stale expanded change extmarks when syncing local diff review", function()
            local review = state.set_local_review(mock_data.local_diff, {
                target = "main",
            })
            review.expanded_changes["src/feature.lua:10"] = { 99, 100 }

            cli.get_local_diff.invokes(function(_, callback)
                callback({
                    git_root = "/tmp/test",
                    files = {
                        { path = "src/synced.lua", status = "modified", change_blocks = {} },
                    },
                }, nil)
            end)

            neo_reviewer.sync()

            local synced_review = state.get_review()
            assert.is_not_nil(synced_review)
            if synced_review then
                assert.are.same({}, synced_review.expanded_changes)
            end
        end)

        it("preserves AI analysis when syncing local diff review", function()
            state.set_local_review(mock_data.local_diff, {
                target = "main",
            })
            local analysis = {
                overview = "Local sync analysis",
                steps = {
                    {
                        title = "Check local changes",
                        summary = "Review important changes first.",
                    },
                },
            }
            state.set_ai_analysis(analysis)

            cli.get_local_diff.invokes(function(_, callback)
                callback({
                    git_root = "/tmp/test",
                    files = {
                        { path = "src/synced.lua", status = "modified", change_blocks = {} },
                    },
                }, nil)
            end)

            neo_reviewer.sync()

            assert.are.same(analysis, state.get_ai_analysis())
        end)

        it("notifies user when local diff sync is in progress", function()
            state.set_local_review(mock_data.local_diff)

            neo_reviewer.sync()

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Syncing local diff") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected 'Syncing local diff...' notification")
        end)

        it("ends local review when sync finds no changes", function()
            state.set_local_review(mock_data.local_diff)

            cli.get_local_diff.invokes(function(_, callback)
                callback({
                    git_root = "/tmp/test",
                    files = {},
                }, nil)
            end)

            neo_reviewer.sync()

            assert.is_nil(state.get_review())

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("No changes to review") and n.level == vim.log.levels.WARN then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected 'No changes to review' warning")
        end)

        it("warns when PR review has no url", function()
            local review = state.set_review(mock_data.simple_pr, "/tmp/test")
            review.url = nil

            neo_reviewer.sync()

            local notifs = notifications.get()
            assert.are.equal(1, #notifs)
            assert.matches("Sync only works for PR reviews", notifs[1].msg)
        end)

        it("fetches PR data via CLI with correct URL", function()
            local review = state.set_review(mock_data.simple_pr, "/tmp/test")
            review.url = "https://github.com/owner/repo/pull/123"

            neo_reviewer.sync()

            assert.stub(cli.fetch_pr).was_called(1)
            assert.stub(cli.fetch_pr).was_called_with("https://github.com/owner/repo/pull/123", match._)
        end)

        it("preserves AI analysis when syncing PR review", function()
            local review = state.set_review(mock_data.simple_pr, "/tmp/test")
            review.url = "https://github.com/owner/repo/pull/123"
            local analysis = {
                overview = "PR sync analysis",
                steps = {
                    {
                        title = "Check API updates",
                        summary = "Confirm backward compatibility.",
                    },
                },
            }
            state.set_ai_analysis(analysis)

            cli.fetch_pr.invokes(function(_, callback)
                callback(mock_data.simple_pr, nil)
            end)

            neo_reviewer.sync()

            assert.are.same(analysis, state.get_ai_analysis())
        end)

        it("clears stale expanded change extmarks when syncing PR review", function()
            local review = state.set_review(mock_data.simple_pr, "/tmp/test")
            review.url = "https://github.com/owner/repo/pull/123"
            review.expanded_changes["src/main.lua:2"] = { 55 }

            cli.fetch_pr.invokes(function(_, callback)
                callback(mock_data.simple_pr, nil)
            end)

            neo_reviewer.sync()

            local synced_review = state.get_review()
            assert.is_not_nil(synced_review)
            if synced_review then
                assert.are.same({}, synced_review.expanded_changes)
            end
        end)

        it("notifies user that sync is in progress", function()
            local review = state.set_review(mock_data.simple_pr, "/tmp/test")
            review.url = "https://github.com/owner/repo/pull/123"

            neo_reviewer.sync()

            local notifs = notifications.get()
            local found = false
            for _, n in ipairs(notifs) do
                if n.msg:match("Syncing PR data") then
                    found = true
                    break
                end
            end
            assert.is_true(found, "Expected 'Syncing PR data...' notification")
        end)
    end)
end)
