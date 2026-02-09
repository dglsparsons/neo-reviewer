local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")
local fixtures = require("fixtures.mock_pr_data")

describe("neo_reviewer Ask walkthrough controls", function()
    local neo_reviewer
    local state
    local walkthrough_ui
    local ai_ui
    local notifications

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.walkthrough"] = nil
        package.loaded["neo_reviewer.ui.ai"] = nil

        neo_reviewer = require("neo_reviewer")
        state = require("neo_reviewer.state")
        walkthrough_ui = require("neo_reviewer.ui.walkthrough")
        ai_ui = require("neo_reviewer.ui.ai")
        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        notifications.restore()
        walkthrough_ui.close()
        state.clear_walkthrough()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("done closes and clears Ask walkthrough sessions", function()
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })
        walkthrough_ui.open()

        assert.is_true(walkthrough_ui.is_open())
        assert.is_not_nil(state.get_walkthrough())

        neo_reviewer.done()

        assert.is_false(walkthrough_ui.is_open())
        assert.is_nil(state.get_walkthrough())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Walkthrough closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("done closes Ask loading window when no walkthrough data exists", function()
        walkthrough_ui.show_loading()
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.done()

        assert.is_false(walkthrough_ui.is_open())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Walkthrough window closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("toggle_ai_feedback toggles Ask walkthrough when no review is active", function()
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })

        assert.is_false(walkthrough_ui.is_open())
        neo_reviewer.toggle_ai_feedback()
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_false(walkthrough_ui.is_open())
    end)

    it("done clears Ask walkthrough even when a review is active", function()
        state.set_local_review(helpers.deep_copy(fixtures.local_diff))
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })
        walkthrough_ui.open()

        assert.is_not_nil(state.get_review())
        assert.is_true(walkthrough_ui.is_open())
        assert.is_not_nil(state.get_walkthrough())

        neo_reviewer.done()

        assert.is_nil(state.get_review())
        assert.is_false(walkthrough_ui.is_open())
        assert.is_nil(state.get_walkthrough())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Review closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("cycles stacked review/Ask visibility in the expected order", function()
        state.set_local_review(helpers.deep_copy(fixtures.local_diff))
        state.set_ai_analysis({
            overview = "Review overview",
            steps = {},
        })
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })

        ai_ui.open()
        walkthrough_ui.open()
        assert.is_true(ai_ui.is_open())
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_false(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(walkthrough_ui.is_open())
        assert.is_true(ai_ui.is_open())
    end)
end)
