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

    describe("show_thread", function()
        it("notifies when not in a review buffer", function()
            helpers.create_test_buffer({ "line 1", "line 2" })

            local notified = false
            local original_notify = vim.notify
            vim.notify = function(msg, level)
                if msg == "Not in a review buffer" then
                    notified = true
                end
            end

            comments.show_thread()

            vim.notify = original_notify
            assert.is_true(notified)
        end)

        it("handles threaded comments with in_reply_to_id", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local file_comments = state.get_comments_for_file("src/foo.lua")
            assert.are.equal(3, #file_comments)

            local root_comment = nil
            local replies = {}
            for _, c in ipairs(file_comments) do
                if not c.in_reply_to_id then
                    root_comment = c
                else
                    table.insert(replies, c)
                end
            end

            assert.is_not_nil(root_comment)
            assert.are.equal(2, #replies)

            if root_comment then
                for _, reply in ipairs(replies) do
                    assert.are.equal(root_comment.id, reply.in_reply_to_id)
                end
            end
        end)
    end)

    describe("LEFT side comments", function()
        it("show_comment maps LEFT side comment to deleted_at position", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            local hunks = {
                {
                    deleted_at = { 3, 3 },
                    deleted_old_lines = { 5, 6 },
                    old_lines = { "deleted line 5", "deleted line 6" },
                },
            }

            comments.show_comment(bufnr, {
                line = 5,
                side = "LEFT",
                body = "Comment on deleted line",
                author = "user",
            }, hunks)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(2, extmarks[1][2])
        end)

        it("show_comment places RIGHT side comment at its line number", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            local hunks = {
                {
                    deleted_at = { 3 },
                    deleted_old_lines = { 5 },
                },
            }

            comments.show_comment(bufnr, {
                line = 2,
                side = "RIGHT",
                body = "Comment on new line",
                author = "user",
            }, hunks)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(1, extmarks[1][2])
        end)

        it("show_existing displays LEFT side comments at mapped position", function()
            local data = {
                pr = { number = 999, title = "Test" },
                files = {
                    {
                        path = "test.lua",
                        status = "modified",
                        hunks = {
                            {
                                start = 1,
                                count = 3,
                                old_start = 1,
                                old_count = 5,
                                hunk_type = "change",
                                old_lines = { "old2", "old3" },
                                added_lines = { 2 },
                                deleted_at = { 2, 2 },
                                deleted_old_lines = { 2, 3 },
                            },
                        },
                    },
                },
                comments = {
                    {
                        id = 100,
                        path = "test.lua",
                        line = 2,
                        side = "LEFT",
                        body = "Comment on deleted line 2",
                        author = "reviewer",
                        created_at = "2024-01-01T12:00:00Z",
                    },
                },
            }
            state.set_review(data)

            local bufnr = helpers.create_test_buffer({ "line 1", "new line 2", "line 3" })

            comments.show_existing(bufnr, "test.lua")

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(1, extmarks[1][2])
        end)

        it("LEFT side comment not displayed if old line not in hunks", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            local hunks = {
                {
                    deleted_at = { 2 },
                    deleted_old_lines = { 5 },
                },
            }

            comments.show_comment(bufnr, {
                line = 10,
                side = "LEFT",
                body = "Comment on unmapped line",
                author = "user",
            }, hunks)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_comments")
            assert.are.equal(0, #extmarks)
        end)
    end)
end)
