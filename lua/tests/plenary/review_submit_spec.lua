local stub = require("luassert.stub")
local match = require("luassert.match")
local helpers = require("plenary.helpers")

describe("neo_reviewer review submission", function()
    local neo_reviewer
    local state
    local cli
    local notifications

    ---@return NRReview
    local function setup_review()
        local review = state.set_review({
            pr = { number = 123, title = "Test PR", author = "pr-author" },
            viewer = "reviewer",
            files = {
                { path = "foo.txt", status = "modified", change_blocks = {} },
            },
            comments = {},
        }, "/tmp/repo")
        review.url = "https://github.com/owner/repo/pull/123"
        state.set_checkout_state("main")
        return review
    end

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.cli"] = nil

        state = require("neo_reviewer.state")
        cli = require("neo_reviewer.cli")

        stub(cli, "submit_review")
        stub(cli, "restore_branch")

        neo_reviewer = require("neo_reviewer")
        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        cli.submit_review:revert()
        cli.restore_branch:revert()

        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    describe("approve", function()
        it("restores previous branch after successful submission", function()
            setup_review()
            cli.submit_review.invokes(function(_, _, _, callback)
                callback(true, nil)
            end)
            cli.restore_branch.invokes(function(_, callback)
                callback(true, nil)
            end)

            neo_reviewer.approve()

            assert.stub(cli.submit_review).was_called_with(
                "https://github.com/owner/repo/pull/123",
                "APPROVE",
                nil,
                match._
            )
            assert.stub(cli.restore_branch).was_called_with("main", match._)
            assert.is_nil(state.get_review())
        end)

        it("does not restore branch when submission fails", function()
            setup_review()
            cli.submit_review.invokes(function(_, _, _, callback)
                callback(false, "submit failed")
            end)

            neo_reviewer.approve()

            assert.stub(cli.restore_branch).was_not_called()
            assert.is_not_nil(state.get_review())
        end)
    end)

    describe("request_changes", function()
        it("restores previous branch after successful submission", function()
            setup_review()
            cli.submit_review.invokes(function(_, _, _, callback)
                callback(true, nil)
            end)
            cli.restore_branch.invokes(function(_, callback)
                callback(true, nil)
            end)

            neo_reviewer.request_changes("Needs work")

            assert.stub(cli.submit_review).was_called_with(
                "https://github.com/owner/repo/pull/123",
                "REQUEST_CHANGES",
                "Needs work",
                match._
            )
            assert.stub(cli.restore_branch).was_called_with("main", match._)
            assert.is_nil(state.get_review())
        end)
    end)
end)
