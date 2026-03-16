local helpers = require("plenary.helpers")
local fixtures = require("fixtures.mock_pr_data")

describe("neo_reviewer.copy_comments", function()
    local neo_reviewer
    local state
    local original_setreg
    local notifications

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.comments"] = nil

        state = require("neo_reviewer.state")
        neo_reviewer = require("neo_reviewer")
        notifications = helpers.capture_notifications()

        original_setreg = vim.fn.setreg
    end)

    after_each(function()
        vim.fn.setreg = original_setreg
        notifications.restore()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("copies local diff comments plus the Codex request stub", function()
        state.set_local_review({ git_root = "/tmp/test-repo", files = {} })
        state.add_comment({
            id = 1,
            path = "src/main.lua",
            line = 42,
            side = "RIGHT",
            body = "Single line comment",
            author = "you",
            created_at = "2024-01-01T12:00:00Z",
        })
        state.add_comment({
            id = 3,
            path = "src/main.lua",
            start_line = 100,
            line = 105,
            side = "RIGHT",
            body = "Range comment",
            author = "you",
            created_at = "2024-01-01T12:05:00Z",
        })

        local copied_register = nil
        local copied_text = nil
        vim.fn.setreg = function(register, value)
            copied_register = register
            copied_text = value
        end

        neo_reviewer.copy_comments()

        assert.are.equal("+", copied_register)
        assert.are.equal(
            "# Diff comments\n\n"
                .. "## Comment 1 (src/main.lua:42)\n"
                .. "Single line comment\n\n"
                .. "## Comment 3 (src/main.lua:100-105)\n"
                .. "Range comment\n\n"
                .. "## My request for Codex:\n",
            copied_text
        )
    end)

    it("copies threaded PR comments plus the Codex request stub", function()
        state.set_review(helpers.deep_copy(fixtures.multi_file_pr))

        local copied_register = nil
        local copied_text = nil
        vim.fn.setreg = function(register, value)
            copied_register = register
            copied_text = value
        end

        neo_reviewer.copy_comments()

        assert.are.equal("+", copied_register)
        assert.are.equal(
            "# PR comments\n\n"
                .. "## Comment 1 (src/foo.lua:2)\n"
                .. "@reviewer 2024-01-01 12:00\n\n"
                .. "Looks good!\n\n"
                .. "### Reply 2 (src/foo.lua:2)\n"
                .. "@author 2024-01-01 13:00\n\n"
                .. "Thanks! I appreciate the feedback.\n\n"
                .. "### Reply 3 (src/foo.lua:2)\n"
                .. "@reviewer 2024-01-01 14:00\n\n"
                .. "No problem, one small thing though - could you add a test?\n\n"
                .. "## My request for Codex:\n",
            copied_text
        )
    end)

    it("warns when there are no comments to copy", function()
        state.set_local_review({ git_root = "/tmp/test-repo", files = {} })

        local copied = false
        vim.fn.setreg = function()
            copied = true
        end

        neo_reviewer.copy_comments()

        assert.is_false(copied)

        local found = false
        for _, n in ipairs(notifications.get()) do
            if n.msg == "No comments to copy" and n.level == vim.log.levels.WARN then
                found = true
                break
            end
        end
        assert.is_true(found, "Expected missing comments warning")
    end)

    it("warns when no review is active", function()
        local copied = false
        vim.fn.setreg = function()
            copied = true
        end

        neo_reviewer.copy_comments()

        assert.is_false(copied)

        local found = false
        for _, n in ipairs(notifications.get()) do
            if n.msg == "No active review" and n.level == vim.log.levels.WARN then
                found = true
                break
            end
        end
        assert.is_true(found, "Expected active review warning")
    end)
end)
