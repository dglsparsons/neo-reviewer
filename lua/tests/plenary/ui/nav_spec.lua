local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer.ui.nav", function()
    local nav
    local state

    before_each(function()
        package.loaded["neo_reviewer.ui.nav"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.ui.comments"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.config"] = nil

        state = require("neo_reviewer.state")
        nav = require("neo_reviewer.ui.nav")
    end)

    after_each(function()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    local function setup_review_buffer(pr_data, file_idx)
        local data = helpers.deep_copy(pr_data)
        state.set_review(data)
        local review = state.get_review()
        review.url = "https://github.com/owner/repo/pull/789"

        local idx = file_idx or 1
        local file = data.files[idx]
        local lines = vim.split(file.content, "\n")
        local bufnr = helpers.create_test_buffer(lines)

        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)

        local buffer = require("neo_reviewer.ui.buffer")
        buffer.place_change_block_marks(bufnr, file)
        require("neo_reviewer.ui.comments").show_existing(bufnr, file.path)

        return bufnr, file
    end

    describe("next_change", function()
        it("jumps to first hunk from before first change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("uses extmark positions after buffer edits", function()
            local bufnr = setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(4, cursor[1])
        end)

        it("jumps to next hunk from within first hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(3)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to next change block within a hunk", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            helpers.set_cursor(2)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("splits contiguous changes when context breaks are present", function()
            local _, file = setup_review_buffer(fixtures.context_split_pr)
            assert.are.equal(2, #file.change_blocks)
            helpers.set_cursor(1)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(2, cursor[1])
        end)

        it("uses change blocks for AI navigation within a hunk", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "Mixed changes",
                        change_blocks = {
                            { file = "mixed.lua", change_block_index = 0 },
                            { file = "mixed.lua", change_block_index = 1 },
                        },
                    },
                },
            })

            helpers.set_cursor(1)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("uses extmark positions for AI navigation after edits", function()
            local bufnr = setup_review_buffer(fixtures.navigation_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "First change",
                        change_blocks = { { file = "test.lua", change_block_index = 0 } },
                    },
                },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })
            helpers.set_cursor(1)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(4, cursor[1])
        end)

        it("uses context-split change blocks for AI navigation", function()
            setup_review_buffer(fixtures.context_split_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "Context split",
                        change_blocks = {
                            { file = "context_split.lua", change_block_index = 0 },
                            { file = "context_split.lua", change_block_index = 1 },
                        },
                    },
                },
            })

            helpers.set_cursor(1)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(2, cursor[1])
        end)

        it("skips duplicate AI change_blocks in order", function()
            setup_review_buffer(fixtures.navigation_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "First change",
                        change_blocks = {
                            { file = "test.lua", change_block_index = 0 },
                            { file = "test.lua", change_block_index = 0 },
                        },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        change_blocks = {
                            { file = "test.lua", change_block_index = 1 },
                        },
                    },
                },
            })
            helpers.set_cursor(3)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("keeps AI order when cursor is inside a hunk", function()
            local pr_data = {
                pr = {
                    number = 321,
                    title = "AI nav mixed files",
                    body = "AI nav mixed files",
                    state = "open",
                    author = "testuser",
                },
                files = {
                    {
                        path = "file_a.lua",
                        status = "modified",
                        additions = 1,
                        deletions = 0,
                        content = table.concat({
                            "a1",
                            "a2",
                            "a3",
                            "a4",
                            "a5",
                        }, "\n"),
                        change_blocks = {
                            {
                                start_line = 3,
                                end_line = 3,
                                kind = "add",
                                added_lines = { 3 },
                                changed_lines = {},
                                deletion_groups = {},
                                old_to_new = {},
                            },
                        },
                    },
                    {
                        path = "file_b.lua",
                        status = "modified",
                        additions = 9,
                        deletions = 0,
                        content = table.concat({
                            "b1",
                            "b2",
                            "b3",
                            "b4",
                            "b5",
                            "b6",
                            "b7",
                            "b8",
                            "b9",
                            "b10",
                            "b11",
                            "b12",
                            "b13",
                            "b14",
                            "b15",
                            "b16",
                            "b17",
                            "b18",
                            "b19",
                            "b20",
                            "b21",
                            "b22",
                            "b23",
                            "b24",
                            "b25",
                            "b26",
                            "b27",
                            "b28",
                            "b29",
                            "b30",
                        }, "\n"),
                        change_blocks = {
                            {
                                start_line = 10,
                                end_line = 17,
                                kind = "add",
                                added_lines = { 10, 11, 12, 13, 14, 15, 16, 17 },
                                changed_lines = {},
                                deletion_groups = {},
                                old_to_new = {},
                            },
                            {
                                start_line = 25,
                                end_line = 25,
                                kind = "add",
                                added_lines = { 25 },
                                changed_lines = {},
                                deletion_groups = {},
                                old_to_new = {},
                            },
                        },
                    },
                },
                comments = {},
            }

            setup_review_buffer(pr_data, 2)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step A",
                        explanation = "First change",
                        change_blocks = { { file = "file_a.lua", change_block_index = 0 } },
                    },
                    {
                        title = "Step B",
                        explanation = "Second change",
                        change_blocks = { { file = "file_b.lua", change_block_index = 0 } },
                    },
                    {
                        title = "Step C",
                        explanation = "Third change",
                        change_blocks = { { file = "file_b.lua", change_block_index = 1 } },
                    },
                },
            })

            helpers.set_cursor(16)

            nav.next_change(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(25, cursor[1])
        end)

        it("continues AI order when cursor leaves the hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "First change",
                        change_blocks = { { file = "test.lua", change_block_index = 0 } },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        change_blocks = { { file = "test.lua", change_block_index = 1 } },
                    },
                    {
                        title = "Step 3",
                        explanation = "Third change",
                        change_blocks = { { file = "test.lua", change_block_index = 2 } },
                    },
                },
            })

            helpers.set_cursor(3)
            nav.next_change(false)

            helpers.set_cursor(1)
            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("jumps to next hunk from between change_blocks", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(5)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to third hunk from second hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(10)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("stays at last hunk when no wrap and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(20)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("wraps to first hunk when wrap=true and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(22)

            nav.next_change(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("does not wrap when wrap=false and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(22)

            nav.next_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("notifies when no active review", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()

            nav.next_change(false)

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No active review", msgs[1].msg)
        end)
    end)

    describe("prev_change", function()
        it("jumps to last hunk from after last change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(25)

            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("jumps to previous hunk from current hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(20)

            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to start of current change block when inside it", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            helpers.set_cursor(6)

            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("jumps to previous hunk from between change_blocks", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(8)

            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("wraps to last hunk when wrap=true and at beginning", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.prev_change(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("does not wrap when wrap=false and at beginning", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(1, cursor[1])
        end)

        it("continues AI order when cursor leaves the hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "First change",
                        change_blocks = { { file = "test.lua", change_block_index = 0 } },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        change_blocks = { { file = "test.lua", change_block_index = 1 } },
                    },
                    {
                        title = "Step 3",
                        explanation = "Third change",
                        change_blocks = { { file = "test.lua", change_block_index = 2 } },
                    },
                },
            })

            helpers.set_cursor(3)
            nav.next_change(false)

            helpers.set_cursor(25)
            nav.prev_change(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)
    end)

    describe("first_change", function()
        it("jumps to first hunk start", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(15)

            nav.first_change()

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)
    end)

    describe("last_change", function()
        it("jumps to last hunk start", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.last_change()

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)
    end)

    describe("next_comment", function()
        it("jumps to first comment from before first comment", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(1)

            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("uses extmark positions after buffer edits", function()
            local bufnr = setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(1)

            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })

            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(6, cursor[1])
        end)

        it("jumps to next comment from first comment", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(5)

            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(15, cursor[1])
        end)

        it("jumps to next comment from between comments", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(10)

            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(15, cursor[1])
        end)

        it("stays at last comment when no wrap and at end", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(22)

            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("wraps to first comment when wrap=true and at end", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(24)

            nav.next_comment(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("notifies when no comments exist", function()
            setup_review_buffer(fixtures.navigation_pr)
            local notifications = helpers.capture_notifications()

            nav.next_comment(false)

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No more comments", msgs[1].msg)
        end)

        it("handles comments with vim.NIL in_reply_to_id (JSON null)", function()
            local data = helpers.deep_copy(fixtures.navigation_pr)
            data.comments = {
                {
                    id = 1,
                    path = "test.lua",
                    line = 10,
                    side = "RIGHT",
                    body = "Comment with vim.NIL",
                    author = "reviewer",
                    created_at = "2024-01-01T12:00:00Z",
                    in_reply_to_id = vim.NIL,
                },
            }
            state.set_review(data)
            local review = state.get_review()
            review.url = "https://github.com/owner/repo/pull/789"

            local file = data.files[1]
            local lines = vim.split(file.content, "\n")
            local bufnr = helpers.create_test_buffer(lines)
            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)

            helpers.set_cursor(1)
            nav.next_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)
    end)

    describe("prev_comment", function()
        it("jumps to last comment from after last comment", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(25)

            nav.prev_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("jumps to previous comment from current comment", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(22)

            nav.prev_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(15, cursor[1])
        end)

        it("jumps to previous comment from between comments", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(12)

            nav.prev_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("wraps to last comment when wrap=true and at beginning", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(1)

            nav.prev_comment(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("does not wrap when wrap=false and at beginning", function()
            setup_review_buffer(fixtures.comment_navigation_pr)
            helpers.set_cursor(1)

            nav.prev_comment(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(1, cursor[1])
        end)
    end)
end)
