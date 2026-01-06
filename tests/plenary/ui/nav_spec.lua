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
        it("jumps to first change line from before first change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)

        it("jumps to next change line within same hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(3)

            nav.next_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(4, cursor[1])
        end)

        it("jumps to next hunk's first change line", function()
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

        it("navigates through consecutive change lines", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(20)

            nav.next_hunk(false)
            assert.are.equal(21, helpers.get_cursor()[1])

            nav.next_hunk(false)
            assert.are.equal(22, helpers.get_cursor()[1])
        end)

        it("wraps to first change when wrap=true and at end", function()
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

        it("notifies when not in review buffer", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()

            nav.next_hunk(false)

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("Not in a review buffer", msgs[1].msg)
        end)
    end)

    describe("prev_hunk", function()
        it("jumps to previous change line from after last change", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(25)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)

        it("jumps to previous change line within same hunk", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(22)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(21, cursor[1])
        end)

        it("jumps to previous hunk's last change line", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(8)

            nav.prev_hunk(false)

            local cursor = helpers.get_cursor()
            assert.are.equal(4, cursor[1])
        end)

        it("wraps to last change when wrap=true and at beginning", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.prev_hunk(true)

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
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
        it("jumps to first change line", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(15)

            nav.first_hunk()

            local cursor = helpers.get_cursor()
            assert.are.equal(3, cursor[1])
        end)
    end)

    describe("last_hunk", function()
        it("jumps to last change line", function()
            setup_review_buffer(fixtures.navigation_pr)
            helpers.set_cursor(1)

            nav.last_hunk()

            local cursor = helpers.get_cursor()
            assert.are.equal(22, cursor[1])
        end)
    end)
end)
