local helpers = require("plenary.helpers")

describe("neo_reviewer.copy_review_feedback", function()
    local neo_reviewer
    local state
    local comments_file
    local original_setreg
    local notifications

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.comments_file"] = nil

        state = require("neo_reviewer.state")
        comments_file = require("neo_reviewer.ui.comments_file")
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

    it("copies REVIEW_COMMENTS.md plus the Codex request stub", function()
        local tempdir = vim.fn.tempname()
        vim.fn.mkdir(tempdir, "p")

        state.set_local_review({ git_root = tempdir, files = {} })
        comments_file.write_all({
            {
                id = 1,
                path = "src/main.lua",
                line = 42,
                side = "RIGHT",
                body = "Single line comment",
                author = "you",
            },
            {
                id = 3,
                path = "src/main.lua",
                start_line = 100,
                line = 105,
                side = "RIGHT",
                body = "Range comment",
                author = "you",
            },
        })

        local copied_register = nil
        local copied_text = nil
        vim.fn.setreg = function(register, value)
            copied_register = register
            copied_text = value
        end

        neo_reviewer.copy_review_feedback()

        local file = io.open(comments_file.get_path(), "r")
        assert.is_not_nil(file)
        ---@cast file file*
        local content = file:read("*a")
        file:close()

        assert.are.equal("+", copied_register)
        assert.are.equal(content .. "\n## My request for Codex:\n", copied_text)

        vim.fn.delete(tempdir, "rf")
    end)

    it("warns when REVIEW_COMMENTS.md does not exist", function()
        local tempdir = vim.fn.tempname()
        vim.fn.mkdir(tempdir, "p")

        state.set_local_review({ git_root = tempdir, files = {} })

        local copied = false
        vim.fn.setreg = function()
            copied = true
        end

        neo_reviewer.copy_review_feedback()

        assert.is_false(copied)

        local found = false
        for _, n in ipairs(notifications.get()) do
            if n.msg == "No REVIEW_COMMENTS.md found" and n.level == vim.log.levels.WARN then
                found = true
                break
            end
        end
        assert.is_true(found, "Expected missing REVIEW_COMMENTS.md warning")

        vim.fn.delete(tempdir, "rf")
    end)
end)
