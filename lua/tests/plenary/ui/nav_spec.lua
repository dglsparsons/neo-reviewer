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

        return bufnr, file
    end

    describe("next_hunk", function()
        it("jumps to first hunk from before first change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("jumps to next hunk from within first hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(3)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to next change block within a hunk", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            helpers.set_cursor(2)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("uses change blocks for AI navigation within a hunk", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "Mixed changes",
                        hunks = { { file = "mixed.lua", hunk_index = 0 } },
                    },
                },
            })

            helpers.set_cursor(1)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("skips duplicate AI hunks in order", function()
            setup_review_buffer(fixtures.navigation_pr)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {
                    {
                        title = "Step 1",
                        explanation = "First change",
                        hunks = {
                            { file = "test.lua", hunk_index = 0 },
                            { file = "test.lua", hunk_index = 0 },
                        },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        hunks = {
                            { file = "test.lua", hunk_index = 1 },
                        },
                    },
                },
            })
            helpers.set_cursor(3)

            nav.next_hunk(false)

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
                        hunks = {
                            {
                                start = 3,
                                count = 1,
                                hunk_type = "add",
                                old_lines = {},
                                added_lines = { 3 },
                                deleted_at = {},
                                deleted_old_lines = {},
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
                        hunks = {
                            {
                                start = 10,
                                count = 8,
                                hunk_type = "add",
                                old_lines = {},
                                added_lines = { 10, 11, 12, 13, 14, 15, 16, 17 },
                                deleted_at = {},
                                deleted_old_lines = {},
                            },
                            {
                                start = 25,
                                count = 1,
                                hunk_type = "add",
                                old_lines = {},
                                added_lines = { 25 },
                                deleted_at = {},
                                deleted_old_lines = {},
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
                        hunks = { { file = "file_a.lua", hunk_index = 0 } },
                    },
                    {
                        title = "Step B",
                        explanation = "Second change",
                        hunks = { { file = "file_b.lua", hunk_index = 0 } },
                    },
                    {
                        title = "Step C",
                        explanation = "Third change",
                        hunks = { { file = "file_b.lua", hunk_index = 1 } },
                    },
                },
            })

            helpers.set_cursor(16)

            nav.next_hunk(true)

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
                        hunks = { { file = "test.lua", hunk_index = 0 } },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        hunks = { { file = "test.lua", hunk_index = 1 } },
                    },
                    {
                        title = "Step 3",
                        explanation = "Third change",
                        hunks = { { file = "test.lua", hunk_index = 2 } },
                    },
                },
            })

            helpers.set_cursor(3)
            nav.next_hunk(false)

            helpers.set_cursor(1)
            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("jumps to next hunk from between hunks", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(5)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to third hunk from second hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(10)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("stays at last hunk when no wrap and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(20)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("wraps to first hunk when wrap=true and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(22)

            nav.next_hunk(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("does not wrap when wrap=false and at end", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(22)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("notifies when no active review", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()

            nav.next_hunk(false)

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No active review", msgs[1].msg)
        end)
    end)

    describe("prev_hunk", function()
        it("jumps to last hunk from after last change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(25)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("jumps to previous hunk from current hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(20)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(10, cursor[1])
        end)

        it("jumps to start of current change block when inside it", function()
            setup_review_buffer(fixtures.mixed_changes_pr)
            helpers.set_cursor(6)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(5, cursor[1])
        end)

        it("jumps to previous hunk from between hunks", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(8)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("wraps to last hunk when wrap=true and at beginning", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.prev_hunk(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(20, cursor[1])
        end)

        it("does not wrap when wrap=false and at beginning", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.prev_hunk(false)

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
                        hunks = { { file = "test.lua", hunk_index = 0 } },
                    },
                    {
                        title = "Step 2",
                        explanation = "Second change",
                        hunks = { { file = "test.lua", hunk_index = 1 } },
                    },
                    {
                        title = "Step 3",
                        explanation = "Third change",
                        hunks = { { file = "test.lua", hunk_index = 2 } },
                    },
                },
            })

            helpers.set_cursor(3)
            nav.next_hunk(false)

            helpers.set_cursor(25)
            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)
    end)

    describe("first_hunk", function()
        it("jumps to first hunk start", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(15)

            nav.first_hunk()

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)
    end)

    describe("last_hunk", function()
        it("jumps to last hunk start", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.last_hunk()

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
