local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("greviewer.ui.virtual", function()
    local virtual
    local state
    local buffer

    before_each(function()
        package.loaded["greviewer.ui.virtual"] = nil
        package.loaded["greviewer.ui.buffer"] = nil
        package.loaded["greviewer.state"] = nil
        package.loaded["greviewer.config"] = nil

        state = require("greviewer.state")
        buffer = require("greviewer.ui.buffer")
        virtual = require("greviewer.ui.virtual")
    end)

    after_each(function()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    local function setup_review_buffer(pr_data)
        local data = helpers.deep_copy(pr_data)
        state.set_review(data)
        local review = state.get_review()
        review.url = "https://github.com/owner/repo/pull/123"

        local file = data.files[1]
        local lines = vim.split(file.content, "\n")
        local bufnr = helpers.create_test_buffer(lines)

        vim.api.nvim_buf_set_var(bufnr, "greviewer_file", file)
        vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", review.url)

        return bufnr, file
    end

    describe("find_hunk_at_line", function()
        it("finds hunk when cursor is at hunk start", function()
            local hunks = {
                { start = 5, count = 3, hunk_type = "change", old_lines = { "old" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 5)
            assert.is_not_nil(hunk)
            assert.are.equal(5, hunk.start)
        end)

        it("finds hunk when cursor is within hunk", function()
            local hunks = {
                { start = 5, count = 3, hunk_type = "change", old_lines = { "old" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 6)
            assert.is_not_nil(hunk)
            assert.are.equal(5, hunk.start)
        end)

        it("finds hunk when cursor is at hunk end", function()
            local hunks = {
                { start = 5, count = 3, hunk_type = "change", old_lines = { "old" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 7)
            assert.is_not_nil(hunk)
        end)

        it("returns nil when cursor is outside hunk", function()
            local hunks = {
                { start = 5, count = 3, hunk_type = "change", old_lines = { "old" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 10)
            assert.is_nil(hunk)
        end)

        it("finds delete hunk at exact line", function()
            local hunks = {
                { start = 5, count = 0, hunk_type = "delete", old_lines = { "deleted" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 5)
            assert.is_not_nil(hunk)
        end)

        it("finds delete hunk at line before", function()
            local hunks = {
                { start = 5, count = 0, hunk_type = "delete", old_lines = { "deleted" } },
            }

            local hunk = virtual.find_hunk_at_line(hunks, 4)
            assert.is_not_nil(hunk)
        end)

        it("returns nil for nil hunks", function()
            local hunk = virtual.find_hunk_at_line(nil, 5)
            assert.is_nil(hunk)
        end)

        it("handles multiple hunks", function()
            local hunks = {
                { start = 3, count = 2, hunk_type = "add", old_lines = {} },
                { start = 10, count = 1, hunk_type = "change", old_lines = { "old" } },
                { start = 20, count = 3, hunk_type = "change", old_lines = { "a", "b", "c" } },
            }

            assert.is_not_nil(virtual.find_hunk_at_line(hunks, 3))
            assert.is_not_nil(virtual.find_hunk_at_line(hunks, 4))
            assert.is_nil(virtual.find_hunk_at_line(hunks, 5))
            assert.is_not_nil(virtual.find_hunk_at_line(hunks, 10))
            assert.is_not_nil(virtual.find_hunk_at_line(hunks, 21))
        end)
    end)

    describe("expand / collapse", function()
        it("creates virtual lines when expanding", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_virtual")
            assert.is_true(#extmarks > 0)
        end)

        it("updates state when expanding", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]

            assert.is_false(state.is_hunk_expanded(file.path, hunk.start))

            virtual.expand(bufnr, hunk, file.path)

            assert.is_true(state.is_hunk_expanded(file.path, hunk.start))
        end)

        it("removes virtual lines when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)
            assert.is_true(#helpers.get_extmarks(bufnr, "greviewer_virtual") > 0)

            virtual.collapse(bufnr, hunk, file.path)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "greviewer_virtual"))
        end)

        it("updates state when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)
            assert.is_true(state.is_hunk_expanded(file.path, hunk.start))

            virtual.collapse(bufnr, hunk, file.path)
            assert.is_false(state.is_hunk_expanded(file.path, hunk.start))
        end)
    end)

    describe("toggle_at_cursor", function()
        it("expands when not expanded", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            helpers.set_cursor(2)

            virtual.toggle_at_cursor()

            assert.is_true(state.is_hunk_expanded(file.path, file.hunks[1].start))
            assert.is_true(#helpers.get_extmarks(bufnr, "greviewer_virtual") > 0)
        end)

        it("collapses when already expanded", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            helpers.set_cursor(2)

            virtual.toggle_at_cursor()
            virtual.toggle_at_cursor()

            assert.is_false(state.is_hunk_expanded(file.path, file.hunks[1].start))
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "greviewer_virtual"))
        end)

        it("notifies when not in review buffer", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()

            virtual.toggle_at_cursor()

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("Not in a review buffer", msgs[1].msg)
        end)

        it("notifies when no hunk at cursor", function()
            local _, file = setup_review_buffer(fixtures.simple_pr)
            helpers.set_cursor(5)
            local notifications = helpers.capture_notifications()

            virtual.toggle_at_cursor()

            local msgs = notifications.get()
            notifications.restore()
            assert.is_true(#msgs > 0)
        end)
    end)

    describe("clear", function()
        it("removes all virtual lines", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]
            virtual.expand(bufnr, hunk, file.path)

            assert.is_true(#helpers.get_extmarks(bufnr, "greviewer_virtual") > 0)

            virtual.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "greviewer_virtual"))
        end)
    end)
end)
