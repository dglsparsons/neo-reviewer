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

        neo_reviewer = require("neo_reviewer")

        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        cli.fetch_pr:revert()

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

        it("warns when trying to sync local diff review", function()
            state.set_local_review(mock_data.local_diff)

            neo_reviewer.sync()

            local notifs = notifications.get()
            assert.are.equal(1, #notifs)
            assert.matches("Sync only works for PR reviews", notifs[1].msg)
            assert.are.equal(vim.log.levels.WARN, notifs[1].level)
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
