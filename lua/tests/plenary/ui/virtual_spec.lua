local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer.ui.virtual", function()
    local virtual
    local state
    local buffer

    before_each(function()
        package.loaded["neo_reviewer.ui.virtual"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.config"] = nil

        state = require("neo_reviewer.state")
        buffer = require("neo_reviewer.ui.buffer")
        virtual = require("neo_reviewer.ui.virtual")
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

        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)

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

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
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
            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)

            virtual.collapse(bufnr, hunk, file.path)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
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
        it("sets global show_old_code state", function()
            setup_review_buffer(fixtures.simple_pr)

            assert.is_false(state.is_showing_old_code())
            virtual.toggle_at_cursor()
            assert.is_true(state.is_showing_old_code())
            virtual.toggle_at_cursor()
            assert.is_false(state.is_showing_old_code())
        end)

        it("expands all hunks in all applied buffers", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)

            virtual.toggle_at_cursor()

            assert.is_true(state.is_hunk_expanded(file.path, file.hunks[1].start))
            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)
        end)

        it("collapses all hunks when toggled off", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)

            virtual.toggle_at_cursor()
            virtual.toggle_at_cursor()

            assert.is_false(state.is_hunk_expanded(file.path, file.hunks[1].start))
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)

        it("notifies when no active review", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()

            virtual.toggle_at_cursor()

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No active review", msgs[1].msg)
        end)
    end)

    describe("clear", function()
        it("removes all virtual lines", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local hunk = file.hunks[1]
            virtual.expand(bufnr, hunk, file.path)

            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)

            virtual.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)
    end)

    describe("non-contiguous deletions", function()
        it("creates separate extmarks for deletions at different positions", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(2, #extmarks)
        end)

        it("anchors scattered deletions to their respective positions", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            local hunk = file.hunks[1]
            -- deleted_at = { 1, 1, 5 } means:
            --   Group 1: deletions at position 1 -> anchor=1, row=0
            --   Group 2: deletion at position 5 -> anchor=5, row=4

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(2, #extmarks)

            -- Sort by row to have predictable order
            table.sort(extmarks, function(a, b)
                return a[2] < b[2]
            end)

            -- First group at position 1 (row 0)
            assert.are.equal(0, extmarks[1][2])
            -- Second group at position 5 (row 4)
            assert.are.equal(4, extmarks[2][2])
        end)

        it("stores multiple extmark IDs in state", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmark_ids = state.get_hunk_extmarks(file.path, hunk.start)
            assert.is_not_nil(extmark_ids)
            assert.are.equal(2, #extmark_ids)
        end)

        it("removes all extmarks when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)
            assert.are.equal(2, #helpers.get_extmarks(bufnr, "nr_virtual"))

            virtual.collapse(bufnr, hunk, file.path)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)
    end)

    describe("anchoring behavior", function()
        it("anchors CHANGE hunk virtual lines to first added line", function()
            local bufnr, file = setup_review_buffer(fixtures.change_hunk_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Extmark should be at row 2 (line 3 - 1 = row index 2)
            -- which is the first added line
            local row = extmarks[1][2]
            assert.are.equal(2, row)
        end)

        it("CHANGE hunk extmarks survive line insertions above anchor", function()
            local bufnr, file = setup_review_buffer(fixtures.change_hunk_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            -- Insert a line at the beginning of the buffer
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })

            -- Extmark should still exist (extmarks move with text)
            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Row should now be 3 (was 2, moved down by 1)
            local row = extmarks[1][2]
            assert.are.equal(3, row)
        end)

        it("anchors DELETE-only hunk virtual lines to deletion position", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Extmark should be at row 2 (deleted_at[1]=3, anchor=3, row=3-1=2)
            -- Virtual lines appear above line 3, showing where deleted content was
            local row = extmarks[1][2]
            assert.are.equal(2, row)
        end)

        it("DELETE-only hunk extmarks survive line insertions above anchor", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            -- Insert a line at the beginning of the buffer
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })

            -- Extmark should still exist (extmarks move with text)
            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Row should now be 3 (was 2, moved down by 1)
            local row = extmarks[1][2]
            assert.are.equal(3, row)
        end)
    end)

    describe("EOF deletion handling", function()
        it("places EOF deletions below the last line", function()
            local bufnr, file = setup_review_buffer(fixtures.eof_deletion_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- File has 3 lines (0-2 rows), anchor_line=4 exceeds line_count
            -- Should clamp to row 2 (last line) with virt_lines_above=false
            local row = extmarks[1][2]
            local details = extmarks[1][4]
            assert.are.equal(2, row)
            assert.is_false(details.virt_lines_above)
        end)

        it("handles empty buffer without crashing", function()
            local data = helpers.deep_copy(fixtures.eof_deletion_pr)
            data.files[1].content = ""
            state.set_review(data)
            local review = state.get_review()
            review.url = "https://github.com/owner/repo/pull/123"

            local file = data.files[1]
            local bufnr = helpers.create_test_buffer({})

            vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
            vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
            state.mark_buffer_applied(bufnr)

            local hunk = file.hunks[1]

            -- Should not error
            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Row should be 0 (clamped from -1), displayed below
            local row = extmarks[1][2]
            local details = extmarks[1][4]
            assert.are.equal(0, row)
            assert.is_false(details.virt_lines_above)
        end)

        it("normal deletions still use virt_lines_above=true", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local hunk = file.hunks[1]

            virtual.expand(bufnr, hunk, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Deletion at line 3 in a 5-line file should use virt_lines_above=true
            local details = extmarks[1][4]
            assert.is_true(details.virt_lines_above)
        end)
    end)
end)
