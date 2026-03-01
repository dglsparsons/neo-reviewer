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
        package.loaded["neo_reviewer.ui.comments_file"] = nil

        state = require("neo_reviewer.state")
        comments = require("neo_reviewer.ui.comments")
    end)

    ---@return table<string, function>
    ---@return fun()
    local function capture_thread_mappings()
        local mappings = {}
        local original_keymap_set = vim.keymap.set
        vim.keymap.set = function(mode, lhs, rhs, opts)
            if opts and opts.buffer then
                mappings[lhs] = rhs
                return
            end
            return original_keymap_set(mode, lhs, rhs, opts)
        end
        return mappings, function()
            vim.keymap.set = original_keymap_set
        end
    end

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

        it("matches LEFT comments clamped before first line", function()
            state.set_local_review({
                git_root = "/tmp/test-repo",
                files = {
                    {
                        path = "test.lua",
                        status = "modified",
                        content = "line 1\nline 2\nline 3",
                        change_blocks = {
                            {
                                start_line = 1,
                                end_line = 1,
                                kind = "delete",
                                added_lines = {},
                                changed_lines = {},
                                deletion_groups = {
                                    {
                                        anchor_line = 0,
                                        old_lines = { "old line 4" },
                                        old_line_numbers = { 4 },
                                    },
                                },
                                old_to_new = {
                                    { old_line = 4, new_line = 0 },
                                },
                            },
                        },
                    },
                },
            })

            state.add_comment({
                id = 101,
                path = "test.lua",
                line = 4,
                side = "LEFT",
                body = "Comment on deleted line",
                author = "you",
                created_at = "2024-01-01T12:00:00Z",
            })

            local file = state.get_review().files[1]
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            helpers.set_cursor(1)

            local no_comments_notified = false
            local original_notify = vim.notify
            vim.notify = function(msg, level, opts)
                if msg == "No comments on this line" then
                    no_comments_notified = true
                    return
                end
                return original_notify(msg, level, opts)
            end

            local mappings, restore_mappings = capture_thread_mappings()
            comments.show_thread()
            restore_mappings()
            vim.notify = original_notify

            assert.is_false(no_comments_notified)
            assert.is_not_nil(next(mappings))
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

        it("edits local comments and rewrites REVIEW_COMMENTS.md", function()
            state.set_local_review({
                git_root = "/tmp/test-repo",
                files = {
                    {
                        path = "test.lua",
                        status = "modified",
                        content = "line 1\nline 2\nline 3",
                        change_blocks = {},
                    },
                },
            })

            state.add_comment({
                id = 101,
                path = "test.lua",
                line = 2,
                side = "RIGHT",
                body = "original local comment",
                author = "you",
                created_at = "2024-01-01T12:00:00Z",
            })

            local review = state.get_review()
            local file = review.files[1]
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            helpers.set_cursor(2)

            local wrote_comments = nil
            package.loaded["neo_reviewer.ui.comments_file"] = {
                write_all = function(comment_list)
                    wrote_comments = comment_list
                    return true
                end,
            }

            local mappings, restore_mappings = capture_thread_mappings()
            comments.show_thread()
            restore_mappings()

            local original_input = comments.open_multiline_input
            comments.open_multiline_input = function(_, callback)
                callback("updated local comment")
            end

            assert.is_function(mappings.e)
            mappings.e()

            comments.open_multiline_input = original_input
            package.loaded["neo_reviewer.ui.comments_file"] = nil

            local file_comments = state.get_comments_for_file("test.lua")
            assert.are.equal("updated local comment", file_comments[1].body)
            assert.is_not_nil(wrote_comments)
            if wrote_comments then
                assert.are.equal("updated local comment", wrote_comments[1].body)
            end
        end)

        it("edits PR comments through CLI", function()
            state.set_review({
                pr = { number = 123, title = "Test PR", author = "author" },
                files = {
                    {
                        path = "src/foo.lua",
                        status = "modified",
                        content = "line 1\nline 2\nline 3",
                        change_blocks = {},
                    },
                },
                comments = {
                    {
                        id = 1,
                        path = "src/foo.lua",
                        line = 2,
                        side = "RIGHT",
                        body = "original pr comment",
                        author = "reviewer",
                        created_at = "2024-01-01T12:00:00Z",
                    },
                },
                viewer = "reviewer",
            })

            local review = state.get_review()
            local file = review.files[1]
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", "https://github.com/owner/repo/pull/123")
            helpers.set_cursor(2)

            local edited = false
            package.loaded["neo_reviewer.cli"] = {
                edit_comment = function(_, comment_id, body, callback)
                    edited = (comment_id == 1 and body == "updated pr comment")
                    callback({ success = true, comment_id = comment_id }, nil)
                end,
                delete_comment = function() end,
                reply_to_comment = function() end,
                add_comment = function() end,
                fetch_comments = function() end,
            }

            local mappings, restore_mappings = capture_thread_mappings()
            comments.show_thread()
            restore_mappings()

            local original_input = comments.open_multiline_input
            comments.open_multiline_input = function(_, callback)
                callback("updated pr comment")
            end

            assert.is_function(mappings.e)
            mappings.e()

            comments.open_multiline_input = original_input
            package.loaded["neo_reviewer.cli"] = nil

            assert.is_true(edited)
            local file_comments = state.get_comments_for_file("src/foo.lua")
            assert.are.equal("updated pr comment", file_comments[1].body)
        end)

        it("deletes comments in local and PR flows", function()
            local original_confirm = vim.fn.confirm
            vim.fn.confirm = function()
                return 1
            end

            -- Local flow
            state.set_local_review({
                git_root = "/tmp/test-repo",
                files = {
                    {
                        path = "local.lua",
                        status = "modified",
                        content = "line 1\nline 2",
                        change_blocks = {},
                    },
                },
            })
            state.add_comment({
                id = 201,
                path = "local.lua",
                line = 2,
                side = "RIGHT",
                body = "delete me local",
                author = "you",
                created_at = "2024-01-01T12:00:00Z",
            })

            package.loaded["neo_reviewer.ui.comments_file"] = {
                write_all = function()
                    return true
                end,
            }

            local local_file = state.get_review().files[1]
            local local_buf = helpers.create_test_buffer({ "line 1", "line 2" })
            vim.api.nvim_buf_set_var(local_buf, "nr_file", local_file)
            helpers.set_cursor(2)

            local local_mappings, restore_local_mappings = capture_thread_mappings()
            comments.show_thread()
            restore_local_mappings()
            assert.is_function(local_mappings.d)
            local_mappings.d()

            assert.are.equal(0, #state.get_comments_for_file("local.lua"))
            package.loaded["neo_reviewer.ui.comments_file"] = nil

            -- PR flow
            state.set_review({
                pr = { number = 124, title = "Delete PR", author = "author" },
                files = {
                    {
                        path = "src/delete.lua",
                        status = "modified",
                        content = "line 1\nline 2",
                        change_blocks = {},
                    },
                },
                comments = {
                    {
                        id = 301,
                        path = "src/delete.lua",
                        line = 2,
                        side = "RIGHT",
                        body = "delete me pr",
                        author = "reviewer",
                        created_at = "2024-01-01T12:00:00Z",
                    },
                },
                viewer = "reviewer",
            })

            local deleted = false
            package.loaded["neo_reviewer.cli"] = {
                delete_comment = function(_, comment_id, callback)
                    deleted = comment_id == 301
                    callback({ success = true, comment_id = comment_id }, nil)
                end,
                edit_comment = function() end,
                reply_to_comment = function() end,
                add_comment = function() end,
                fetch_comments = function() end,
            }

            local pr_file = state.get_review().files[1]
            local pr_buf = helpers.create_test_buffer({ "line 1", "line 2" })
            vim.api.nvim_buf_set_var(pr_buf, "nr_file", pr_file)
            vim.api.nvim_buf_set_var(pr_buf, "nr_pr_url", "https://github.com/owner/repo/pull/124")
            helpers.set_cursor(2)

            local pr_mappings, restore_pr_mappings = capture_thread_mappings()
            comments.show_thread()
            restore_pr_mappings()
            assert.is_function(pr_mappings.d)
            pr_mappings.d()

            assert.is_true(deleted)
            assert.are.equal(0, #state.get_comments_for_file("src/delete.lua"))

            package.loaded["neo_reviewer.cli"] = nil
            vim.fn.confirm = original_confirm
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
            comments.add_pr_comment = function(_, _, _, end_pos, _, _)
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

    describe("add_pr_comment", function()
        it("stores LEFT comment coordinates on diff side and renders immediately", function()
            local data = {
                pr = { number = 102, title = "Left comment PR" },
                viewer = "reviewer",
                files = {
                    {
                        path = "test.lua",
                        status = "modified",
                        content = table.concat({
                            "line 1",
                            "line 2",
                            "line 3",
                            "line 4",
                            "line 5",
                        }, "\n"),
                        change_blocks = {
                            {
                                start_line = 3,
                                end_line = 3,
                                kind = "delete",
                                added_lines = {},
                                changed_lines = {},
                                deletion_groups = {
                                    {
                                        anchor_line = 3,
                                        old_lines = { "old line 5" },
                                        old_line_numbers = { 5 },
                                    },
                                },
                                old_to_new = {
                                    { old_line = 5, new_line = 3 },
                                },
                            },
                        },
                    },
                },
                comments = {},
            }
            state.set_review(data)
            local file = data.files[1]
            local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))

            package.loaded["neo_reviewer.cli"] = {
                add_comment = function(_, _, callback)
                    callback({ success = true, comment_id = 7001 }, nil)
                end,
            }

            comments.add_pr_comment(
                file,
                "https://github.com/owner/repo/pull/102",
                3,
                { line = 5, side = "LEFT" },
                nil,
                "Comment on deleted line"
            )

            package.loaded["neo_reviewer.cli"] = nil

            local file_comments = state.get_comments_for_file("test.lua")
            assert.are.equal(1, #file_comments)
            assert.are.equal(5, file_comments[1].line)
            assert.are.equal("LEFT", file_comments[1].side)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(2, extmarks[1][2])
        end)

        it("stores LEFT range start_line on diff side coordinates", function()
            local data = {
                pr = { number = 103, title = "Left range PR" },
                viewer = "reviewer",
                files = {
                    {
                        path = "range.lua",
                        status = "modified",
                        content = "line 1\nline 2\nline 3",
                        change_blocks = {},
                    },
                },
                comments = {},
            }
            state.set_review(data)
            local file = data.files[1]
            helpers.create_test_buffer(vim.split(file.content, "\n"))

            package.loaded["neo_reviewer.cli"] = {
                add_comment = function(_, _, callback)
                    callback({ success = true, comment_id = 7002 }, nil)
                end,
            }

            comments.add_pr_comment(
                file,
                "https://github.com/owner/repo/pull/103",
                2,
                { line = 20, side = "LEFT" },
                { line = 18, side = "LEFT" },
                "Range comment"
            )

            package.loaded["neo_reviewer.cli"] = nil

            local file_comments = state.get_comments_for_file("range.lua")
            assert.are.equal(1, #file_comments)
            assert.are.equal(20, file_comments[1].line)
            assert.are.equal(18, file_comments[1].start_line)
            assert.are.equal("LEFT", file_comments[1].side)
            assert.are.equal("LEFT", file_comments[1].start_side)
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

        it("clamps mapped LEFT side comment before first line", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            local change_blocks = {
                {
                    start_line = 1,
                    end_line = 1,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        {
                            anchor_line = 0,
                            old_lines = { "deleted line 4" },
                            old_line_numbers = { 4 },
                        },
                    },
                    old_to_new = {
                        { old_line = 4, new_line = 0 },
                    },
                },
            }

            assert.has_no_errors(function()
                comments.show_comment(bufnr, {
                    line = 4,
                    side = "LEFT",
                    body = "Comment on deleted line",
                    author = "user",
                }, change_blocks)
            end)

            local extmarks = helpers.get_extmarks(bufnr, "nr_comments")
            assert.are.equal(1, #extmarks)
            assert.are.equal(0, extmarks[1][2])
        end)
    end)

    describe("comments_file persistence", function()
        it("writes local comments in markdown format", function()
            local comments_file = require("neo_reviewer.ui.comments_file")
            local tempdir = vim.fn.tempname()
            vim.fn.mkdir(tempdir, "p")

            state.set_local_review({ git_root = tempdir, files = {} })

            local ok = comments_file.write_all({
                {
                    id = 1,
                    path = "src/main.lua",
                    line = 42,
                    side = "RIGHT",
                    body = "Single line comment",
                    author = "you",
                },
                {
                    id = 2,
                    path = "src/main.lua",
                    start_line = 100,
                    line = 105,
                    side = "RIGHT",
                    body = "Range comment",
                    author = "you",
                },
            })

            assert.is_true(ok)

            local file = io.open(comments_file.get_path(), "r")
            assert.is_not_nil(file)
            ---@cast file file*
            local content = file:read("*a")
            file:close()

            assert.is_not_nil(content:find("# Review Comments", 1, true))
            assert.is_not_nil(content:find("## file=src/main.lua:line=42", 1, true))
            assert.is_not_nil(content:find("## file=src/main.lua:line=100-105", 1, true))

            vim.fn.delete(tempdir, "rf")
        end)

        it("skips malformed comments when writing file", function()
            local comments_file = require("neo_reviewer.ui.comments_file")
            local tempdir = vim.fn.tempname()
            vim.fn.mkdir(tempdir, "p")

            state.set_local_review({ git_root = tempdir, files = {} })

            local ok = comments_file.write_all({
                {
                    id = 1,
                    body = "missing path and line",
                    author = "you",
                },
                {
                    id = 2,
                    path = "src/valid.lua",
                    line = 5,
                    side = "RIGHT",
                    body = "valid",
                    author = "you",
                },
            })

            assert.is_true(ok)

            local file = io.open(comments_file.get_path(), "r")
            assert.is_not_nil(file)
            ---@cast file file*
            local content = file:read("*a")
            file:close()

            assert.is_nil(content:find("missing path and line", 1, true))
            assert.is_not_nil(content:find("src/valid.lua", 1, true))

            vim.fn.delete(tempdir, "rf")
        end)
    end)
end)
