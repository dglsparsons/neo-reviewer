local stub = require("luassert.stub")
local helpers = require("plenary.helpers")

describe("neo_reviewer review_diff noise filtering", function()
    local neo_reviewer
    local state
    local cli
    local config
    local nav
    local comments_file
    local notifications

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
        package.loaded["neo_reviewer.ui.comments_file"] = nil

        state = require("neo_reviewer.state")
        cli = require("neo_reviewer.cli")
        config = require("neo_reviewer.config")
        neo_reviewer = require("neo_reviewer")
        nav = require("neo_reviewer.ui.nav")
        comments_file = require("neo_reviewer.ui.comments_file")

        stub(neo_reviewer, "enable_overlay")
        stub(nav, "first_change")
        stub(comments_file, "clear")

        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        neo_reviewer.enable_overlay:revert()
        nav.first_change:revert()
        comments_file.clear:revert()

        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("skips default noise files in local diff reviews", function()
        cli.get_local_diff = function(callback)
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
        cli.get_local_diff = function(callback)
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
        cli.get_local_diff = function(callback)
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
end)
