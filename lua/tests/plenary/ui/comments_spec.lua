local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer.ui.comments", function()
    local comments
    local state

    before_each(function()
        package.loaded["neo_reviewer.ui.comments"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.config"] = nil
        package.loaded["neo_reviewer.cli"] = nil

        state = require("neo_reviewer.state")
        comments = require("neo_reviewer.ui.comments")
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

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
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

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
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

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.is_true(#extmarks > 0)
        end)

        it("shows no comments for file without comments", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            comments.show_existing(bufnr, "src/bar.lua")

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
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

            assert.is_true(#helpers.get_extmarks(bufnr, "nr_comments") > 0)

            comments.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_comments"))
        end)
    end)

    describe("show_thread", function()
        it("notifies when not in a review buffer", function()
            helpers.create_test_buffer({ "line 1", "line 2" })

            local notified = false
            local original_notify = vim.notify
            vim.notify = function(msg)
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

    describe("parse_suggestion", function()
        it("returns nil for comment without suggestion", function()
            local result = comments.parse_suggestion("This is a regular comment")
            assert.is_nil(result)
        end)

        it("returns nil for nil body", function()
            local result = comments.parse_suggestion(nil)
            assert.is_nil(result)
        end)

        it("parses single-line suggestion", function()
            local body = "Consider this:\n\n```suggestion\nlocal x = 1\n```"
            local result = comments.parse_suggestion(body)

            assert.is_not_nil(result)
            assert.are.same({ "Consider this:", "" }, result.before_text)
            assert.are.same({ "local x = 1" }, result.suggestion_lines)
            assert.are.same({}, result.after_text)
        end)

        it("parses multi-line suggestion", function()
            local body = "Update:\n\n```suggestion\nline 1\nline 2\nline 3\n```"
            local result = comments.parse_suggestion(body)

            assert.is_not_nil(result)
            assert.are.same({ "line 1", "line 2", "line 3" }, result.suggestion_lines)
        end)

        it("parses suggestion with text after", function()
            local body = "Before\n\n```suggestion\ncode\n```\n\nAfter text"
            local result = comments.parse_suggestion(body)

            assert.is_not_nil(result)
            assert.are.same({ "Before", "" }, result.before_text)
            assert.are.same({ "code" }, result.suggestion_lines)
            assert.are.same({ "", "After text" }, result.after_text)
        end)

        it("parses empty suggestion", function()
            local body = "Delete this line:\n\n```suggestion\n```"
            local result = comments.parse_suggestion(body)

            assert.is_not_nil(result)
            assert.are.same({}, result.suggestion_lines)
        end)

        it("handles suggestion block at start of body", function()
            local body = "```suggestion\nreplacement\n```"
            local result = comments.parse_suggestion(body)

            assert.is_not_nil(result)
            assert.are.same({}, result.before_text)
            assert.are.same({ "replacement" }, result.suggestion_lines)
        end)
    end)

    describe("comment side selection", function()
        it("uses RIGHT side for replacement lines", function()
            local data = {
                pr = { number = 101, title = "Replacement PR" },
                files = {
                    {
                        path = "test.lua",
                        status = "modified",
                        content = table.concat({
                            "line 1",
                            "new line 2",
                            "line 3",
                        }, "\n"),
                        change_blocks = {
                            {
                                start_line = 2,
                                end_line = 2,
                                kind = "change",
                                added_lines = { 2 },
                                changed_lines = { 2 },
                                deletion_groups = {
                                    {
                                        anchor_line = 2,
                                        old_lines = { "old line 2" },
                                        old_line_numbers = { 2 },
                                    },
                                },
                                old_to_new = {
                                    { old_line = 2, new_line = 2 },
                                },
                            },
                        },
                    },
                },
                comments = {},
            }
            state.set_review(data)
            local review = state.get_review()
            review.url = "https://github.com/owner/repo/pull/101"

            local file = data.files[1]
            local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)

            local original_input = comments.open_multiline_input
            local original_add = comments.add_pr_comment
            local captured = nil

            comments.open_multiline_input = function(_, callback)
                callback("Test comment")
            end
            comments.add_pr_comment = function(_, _, _, _, end_pos, _, _)
                captured = end_pos
            end

            helpers.set_cursor(2)
            comments.add_at_cursor()

            comments.open_multiline_input = original_input
            comments.add_pr_comment = original_add

            assert.is_not_nil(captured)
            ---@cast captured NRCommentPosition
            assert.are.equal("RIGHT", captured.side)
            assert.are.equal(2, captured.line)
        end)
    end)

    describe("LEFT side comments", function()
        it("show_comment maps LEFT side comment to deleted_at position", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            local change_blocks = {
                {
                    start_line = 3,
                    end_line = 3,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        {
                            anchor_line = 3,
                            old_lines = { "deleted line 5", "deleted line 6" },
                            old_line_numbers = { 5, 6 },
                        },
                    },
                    old_to_new = {
                        { old_line = 5, new_line = 3 },
                        { old_line = 6, new_line = 3 },
                    },
                },
            }

            comments.show_comment(bufnr, {
                line = 5,
                side = "LEFT",
                body = "Comment on deleted line",
                author = "user",
            }, change_blocks)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(2, extmarks[1][2])
        end)

        it("show_comment places RIGHT side comment at its line number", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            local change_blocks = {
                {
                    start_line = 3,
                    end_line = 3,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        {
                            anchor_line = 3,
                            old_lines = { "deleted line 5" },
                            old_line_numbers = { 5 },
                        },
                    },
                    old_to_new = {
                        { old_line = 5, new_line = 3 },
                    },
                },
            }

            comments.show_comment(bufnr, {
                line = 2,
                side = "RIGHT",
                body = "Comment on new line",
                author = "user",
            }, change_blocks)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
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
                        change_blocks = {
                            {
                                start_line = 2,
                                end_line = 2,
                                kind = "change",
                                added_lines = { 2 },
                                changed_lines = { 2 },
                                deletion_groups = {
                                    {
                                        anchor_line = 2,
                                        old_lines = { "old2", "old3" },
                                        old_line_numbers = { 2, 3 },
                                    },
                                },
                                old_to_new = {
                                    { old_line = 2, new_line = 2 },
                                    { old_line = 3, new_line = 2 },
                                },
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

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(1, extmarks[1][2])
        end)

        it("LEFT side comment not displayed if old line not in hunks", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            local change_blocks = {
                {
                    start_line = 2,
                    end_line = 2,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        {
                            anchor_line = 2,
                            old_lines = { "deleted line 5" },
                            old_line_numbers = { 5 },
                        },
                    },
                    old_to_new = {
                        { old_line = 5, new_line = 2 },
                    },
                },
            }

            comments.show_comment(bufnr, {
                line = 10,
                side = "LEFT",
                body = "Comment on unmapped line",
                author = "user",
            }, change_blocks)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(0, #extmarks)
        end)

        it("clamps LEFT side comment past EOF to last line", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            local change_blocks = {
                {
                    start_line = 4,
                    end_line = 4,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        {
                            anchor_line = 4,
                            old_lines = { "deleted line 4" },
                            old_line_numbers = { 4 },
                        },
                    },
                    old_to_new = {
                        { old_line = 4, new_line = 4 },
                    },
                },
            }

            comments.show_comment(bufnr, {
                line = 4,
                side = "LEFT",
                body = "Comment on deleted line",
                author = "user",
            }, change_blocks)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(2, extmarks[1][2])
        end)
    end)
end)
