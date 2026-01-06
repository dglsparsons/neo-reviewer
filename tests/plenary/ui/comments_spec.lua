local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("greviewer.ui.comments", function()
    local comments
    local state

    before_each(function()
        package.loaded["greviewer.ui.comments"] = nil
        package.loaded["greviewer.ui.buffer"] = nil
        package.loaded["greviewer.state"] = nil
        package.loaded["greviewer.config"] = nil
        package.loaded["greviewer.cli"] = nil

        state = require("greviewer.state")
        comments = require("greviewer.ui.comments")
    end)

    after_each(function()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    describe("show_comment", function()
        it("creates extmark for comment", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            comments.show_comment(bufnr, {
                line = 2,
                body = "Test comment",
                author = "user",
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.is_true(#extmarks > 0)
        end)

        it("truncates long comments", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            local long_body = string.rep("x", 100)
            comments.show_comment(bufnr, {
                line = 2,
                body = long_body,
                author = "user",
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.is_true(#extmarks > 0)
        end)

        it("handles comments without line number", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                comments.show_comment(bufnr, {
                    body = "No line",
                    author = "user",
                })
            end)
        end)

        it("handles line number beyond buffer", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                comments.show_comment(bufnr, {
                    line = 999,
                    body = "Beyond buffer",
                    author = "user",
                })
            end)
        end)
    end)

    describe("show_existing", function()
        it("displays comments from state", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            comments.show_existing(bufnr, "src/foo.lua")

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.is_true(#extmarks > 0)
        end)

        it("shows no comments for file without comments", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            comments.show_existing(bufnr, "src/bar.lua")

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.are.equal(0, #extmarks)
        end)

        it("handles no active review gracefully", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                comments.show_existing(bufnr, "any.lua")
            end)
        end)
    end)

    describe("clear", function()
        it("removes all comment extmarks", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            comments.show_comment(bufnr, {
                line = 1,
                body = "Comment 1",
                author = "user",
            })
            comments.show_comment(bufnr, {
                line = 2,
                body = "Comment 2",
                author = "user",
            })

            assert.is_true(#helpers.get_extmarks(bufnr, "greviewer_comments") > 0)

            comments.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "greviewer_comments"))
        end)
    end)
end)
