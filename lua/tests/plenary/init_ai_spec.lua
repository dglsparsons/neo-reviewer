local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer init AI auto-open", function()
    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.cli"] = nil
        package.loaded["neo_reviewer.ai"] = nil
        package.loaded["neo_reviewer.ui.ai"] = nil
        package.loaded["neo_reviewer.config"] = nil
    end)

    after_each(function()
        helpers.clear_all_buffers()
    end)

    it("auto-opens walkthrough on local diff analysis", function()
        local cli = require("neo_reviewer.cli")
        local config = require("neo_reviewer.config")

        config.setup({ ai = { enabled = true } })

        local review_data = helpers.deep_copy(fixtures.navigation_pr)
        cli.get_local_diff = function(_, callback)
            callback({ git_root = "/tmp", files = review_data.files }, nil)
        end
        cli.get_git_root = function()
            return "/tmp"
        end
        cli.is_worktree_dirty = function()
            return false
        end

        local ai = require("neo_reviewer.ai")
        ai.analyze_pr = function(_, callback)
            callback({ overview = "Test overview", steps = {} }, nil)
        end

        local called = 0
        local ai_ui = require("neo_reviewer.ui.ai")
        ai_ui.open = function()
            called = called + 1
        end

        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.review_diff({ analyze = true })

        assert.are.equal(1, called)
    end)
end)
