local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("greviewer.ui.nav", function()
    local nav
    local state

    before_each(function()
        package.loaded["greviewer.ui.nav"] = nil
        package.loaded["greviewer.ui.buffer"] = nil
        package.loaded["greviewer.state"] = nil
        package.loaded["greviewer.config"] = nil

        state = require("greviewer.state")
        nav = require("greviewer.ui.nav")
    end)

    after_each(function()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    local function setup_review_buffer(pr_data)
        local data = helpers.deep_copy(pr_data)
        state.set_review(data)
        local review = state.get_review()
        review.url = "https://github.com/owner/repo/pull/789"

        local file = data.files[1]
        local lines = vim.split(file.content, "\n")
        local bufnr = helpers.create_test_buffer(lines)

        vim.api.nvim_buf_set_var(bufnr, "greviewer_file", file)
        vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", review.url)

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
            vim.api.nvim_buf_set_var(bufnr, "greviewer_file", file)
            vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", review.url)

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
