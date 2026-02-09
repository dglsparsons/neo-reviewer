local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer.ui.virtual", function()
    local virtual
    local state
    before_each(function()
        package.loaded["neo_reviewer.ui.virtual"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.config"] = nil

        state = require("neo_reviewer.state")
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

    describe("find_change_block_at_line", function()
        it("finds change block when cursor is at block start", function()
            local change_blocks = {
                { start_line = 5, end_line = 7, kind = "change" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 5)
            assert.is_not_nil(block)
            assert.are.equal(5, block.start_line)
        end)

        it("finds change block when cursor is within block", function()
            local change_blocks = {
                { start_line = 5, end_line = 7, kind = "change" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 6)
            assert.is_not_nil(block)
            assert.are.equal(5, block.start_line)
        end)

        it("finds change block when cursor is at block end", function()
            local change_blocks = {
                { start_line = 5, end_line = 7, kind = "change" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 7)
            assert.is_not_nil(block)
        end)

        it("returns nil when cursor is outside block", function()
            local change_blocks = {
                { start_line = 5, end_line = 7, kind = "change" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 10)
            assert.is_nil(block)
        end)

        it("finds delete block at exact line", function()
            local change_blocks = {
                { start_line = 5, end_line = 5, kind = "delete" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 5)
            assert.is_not_nil(block)
        end)

        it("finds delete block at line before", function()
            local change_blocks = {
                { start_line = 5, end_line = 5, kind = "delete" },
            }

            local block = virtual.find_change_block_at_line(change_blocks, 4)
            assert.is_not_nil(block)
        end)

        it("returns nil for nil change blocks", function()
            local block = virtual.find_change_block_at_line(nil, 5)
            assert.is_nil(block)
        end)

        it("handles multiple change blocks", function()
            local change_blocks = {
                { start_line = 3, end_line = 4, kind = "add" },
                { start_line = 10, end_line = 10, kind = "change" },
                { start_line = 20, end_line = 22, kind = "change" },
            }

            assert.is_not_nil(virtual.find_change_block_at_line(change_blocks, 3))
            assert.is_not_nil(virtual.find_change_block_at_line(change_blocks, 4))
            assert.is_nil(virtual.find_change_block_at_line(change_blocks, 5))
            assert.is_not_nil(virtual.find_change_block_at_line(change_blocks, 10))
            assert.is_not_nil(virtual.find_change_block_at_line(change_blocks, 21))
        end)
    end)

    describe("expand / collapse", function()
        it("creates virtual lines when expanding", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.is_true(#extmarks > 0)
        end)

        it("updates state when expanding", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]

            assert.is_false(state.is_change_expanded(file.path, block.start_line))

            virtual.expand(bufnr, block, file.path)

            assert.is_true(state.is_change_expanded(file.path, block.start_line))
        end)

        it("removes virtual lines when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)
            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)

            virtual.collapse(bufnr, block, file.path)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)

        it("updates state when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)
            assert.is_true(state.is_change_expanded(file.path, block.start_line))

            virtual.collapse(bufnr, block, file.path)
            assert.is_false(state.is_change_expanded(file.path, block.start_line))
        end)
    end)

    describe("toggle_at_cursor", function()
        it("toggles old code preview for the change block at cursor", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]

            helpers.set_cursor(block.start_line)

            virtual.toggle_at_cursor()

            assert.is_true(state.is_change_expanded(file.path, block.start_line))
            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)

            virtual.toggle_at_cursor()

            assert.is_false(state.is_change_expanded(file.path, block.start_line))
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)

        it("only toggles the block under cursor", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            local first_block = file.change_blocks[1]
            local second_block = file.change_blocks[2]

            helpers.set_cursor(first_block.start_line)
            virtual.toggle_at_cursor()

            assert.is_true(state.is_change_expanded(file.path, first_block.start_line))
            assert.is_false(state.is_change_expanded(file.path, second_block.start_line))
            assert.are.equal(1, #helpers.get_extmarks(bufnr, "nr_virtual"))
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

        it("notifies when cursor is outside change blocks", function()
            setup_review_buffer(fixtures.simple_pr)
            helpers.set_cursor(1)
            local notifications = helpers.capture_notifications()

            virtual.toggle_at_cursor()

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No change block at cursor", msgs[1].msg)
        end)

        it("notifies when block has no deleted lines", function()
            setup_review_buffer(fixtures.multi_file_pr)
            helpers.set_cursor(1)
            local notifications = helpers.capture_notifications()

            virtual.toggle_at_cursor()

            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("has no deleted lines", msgs[1].msg)
        end)
    end)

    describe("toggle_review_mode", function()
        it("toggles old code preview for all hunks in the current file", function()
            local bufnr, file = setup_review_buffer(fixtures.comment_navigation_pr)
            ---@type NRChangeBlock[]
            local blocks_with_deletions = {}

            for _, block in ipairs(file.change_blocks) do
                if block.deletion_groups and #block.deletion_groups > 0 then
                    table.insert(blocks_with_deletions, block)
                end
            end

            assert.are.equal(2, #blocks_with_deletions)
            assert.is_false(state.is_showing_old_code())

            virtual.toggle_review_mode()

            assert.is_true(state.is_showing_old_code())
            for _, block in ipairs(blocks_with_deletions) do
                assert.is_true(state.is_change_expanded(file.path, block.start_line))
            end
            assert.are.equal(2, #helpers.get_extmarks(bufnr, "nr_virtual"))

            virtual.toggle_review_mode()

            assert.is_false(state.is_showing_old_code())
            for _, block in ipairs(blocks_with_deletions) do
                assert.is_false(state.is_change_expanded(file.path, block.start_line))
            end
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)

        it("applies mode changes to all applied review buffers", function()
            local data = {
                pr = {
                    number = 123,
                    title = "Two files",
                },
                files = {
                    {
                        path = "a.lua",
                        status = "modified",
                        content = "line 1\nline 2\nline 3",
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
                    {
                        path = "b.lua",
                        status = "modified",
                        content = "line 10\nline 11\nline 12",
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
                                        old_lines = { "old line 11" },
                                        old_line_numbers = { 11 },
                                    },
                                },
                                old_to_new = {
                                    { old_line = 11, new_line = 2 },
                                },
                            },
                        },
                    },
                },
                comments = {},
            }
            state.set_review(data)
            local review = state.get_review()
            review.url = "https://github.com/owner/repo/pull/123"

            local file_a = data.files[1]
            local file_b = data.files[2]
            local bufnr_a = helpers.create_test_buffer(vim.split(file_a.content, "\n"))
            local bufnr_b = helpers.create_test_buffer(vim.split(file_b.content, "\n"))

            vim.api.nvim_buf_set_var(bufnr_a, "nr_file", file_a)
            vim.api.nvim_buf_set_var(bufnr_a, "nr_pr_url", review.url)
            state.mark_buffer_applied(bufnr_a)

            vim.api.nvim_buf_set_var(bufnr_b, "nr_file", file_b)
            vim.api.nvim_buf_set_var(bufnr_b, "nr_pr_url", review.url)
            state.mark_buffer_applied(bufnr_b)

            vim.api.nvim_set_current_buf(bufnr_a)
            virtual.toggle_review_mode()

            assert.is_true(state.is_showing_old_code())
            assert.is_true(state.is_change_expanded(file_a.path, 2))
            assert.is_true(state.is_change_expanded(file_b.path, 2))
            assert.are.equal(1, #helpers.get_extmarks(bufnr_a, "nr_virtual"))
            assert.are.equal(1, #helpers.get_extmarks(bufnr_b, "nr_virtual"))

            virtual.toggle_review_mode()

            assert.is_false(state.is_showing_old_code())
            assert.is_false(state.is_change_expanded(file_a.path, 2))
            assert.is_false(state.is_change_expanded(file_b.path, 2))
            assert.are.equal(0, #helpers.get_extmarks(bufnr_a, "nr_virtual"))
            assert.are.equal(0, #helpers.get_extmarks(bufnr_b, "nr_virtual"))
        end)

        it("notifies when no active review", function()
            helpers.create_test_buffer({ "not", "a", "review" })
            local notifications = helpers.capture_notifications()
            virtual.toggle_review_mode()
            local msgs = notifications.get()
            notifications.restore()
            assert.are.equal(1, #msgs)
            assert.matches("No active review", msgs[1].msg)
        end)
    end)

    describe("clear", function()
        it("removes all virtual lines", function()
            local bufnr, file = setup_review_buffer(fixtures.simple_pr)
            local block = file.change_blocks[1]
            virtual.expand(bufnr, block, file.path)

            assert.is_true(#helpers.get_extmarks(bufnr, "nr_virtual") > 0)

            virtual.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)
    end)

    describe("non-contiguous deletions", function()
        it("creates separate extmarks for deletions at different positions", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            for _, block in ipairs(file.change_blocks) do
                virtual.expand(bufnr, block, file.path)
            end

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(2, #extmarks)
        end)

        it("anchors scattered deletions to their respective positions", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            for _, block in ipairs(file.change_blocks) do
                virtual.expand(bufnr, block, file.path)
            end

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
            for _, block in ipairs(file.change_blocks) do
                virtual.expand(bufnr, block, file.path)
                local extmark_ids = state.get_change_extmarks(file.path, block.start_line)
                assert.is_not_nil(extmark_ids)
                assert.are.equal(1, #extmark_ids)
            end
        end)

        it("removes all extmarks when collapsing", function()
            local bufnr, file = setup_review_buffer(fixtures.mixed_changes_pr)
            for _, block in ipairs(file.change_blocks) do
                virtual.expand(bufnr, block, file.path)
            end
            assert.are.equal(2, #helpers.get_extmarks(bufnr, "nr_virtual"))

            for _, block in ipairs(file.change_blocks) do
                virtual.collapse(bufnr, block, file.path)
            end
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_virtual"))
        end)
    end)

    describe("anchoring behavior", function()
        it("anchors CHANGE block virtual lines to first added line", function()
            local bufnr, file = setup_review_buffer(fixtures.change_hunk_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Extmark should be at row 2 (line 3 - 1 = row index 2)
            -- which is the first added line
            local row = extmarks[1][2]
            assert.are.equal(2, row)
        end)

        it("CHANGE block extmarks survive line insertions above anchor", function()
            local bufnr, file = setup_review_buffer(fixtures.change_hunk_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            -- Insert a line at the beginning of the buffer
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted line" })

            -- Extmark should still exist (extmarks move with text)
            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Row should now be 3 (was 2, moved down by 1)
            local row = extmarks[1][2]
            assert.are.equal(3, row)
        end)

        it("anchors DELETE-only block virtual lines to deletion position", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Extmark should be at row 2 (deleted_at[1]=3, anchor=3, row=3-1=2)
            -- Virtual lines appear above line 3, showing where deleted content was
            local row = extmarks[1][2]
            assert.are.equal(2, row)
        end)

        it("DELETE-only block extmarks survive line insertions above anchor", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

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
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- File has 3 lines (0-2 rows), anchor_line=4 exceeds line_count
            -- Should clamp to row 2 (last line) with virt_lines_above=false
            local row = extmarks[1][2]
            local details = assert(extmarks[1][4])
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

            local block = file.change_blocks[1]

            -- Should not error
            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Row should be 0 (clamped from -1), displayed below
            local row = extmarks[1][2]
            local details = assert(extmarks[1][4])
            assert.are.equal(0, row)
            assert.is_false(details.virt_lines_above)
        end)

        it("normal deletions still use virt_lines_above=true", function()
            local bufnr, file = setup_review_buffer(fixtures.delete_only_pr)
            local block = file.change_blocks[1]

            virtual.expand(bufnr, block, file.path)

            local extmarks = helpers.get_extmarks(bufnr, "nr_virtual")
            assert.are.equal(1, #extmarks)
            -- Deletion at line 3 in a 5-line file should use virt_lines_above=true
            local details = assert(extmarks[1][4])
            assert.is_true(details.virt_lines_above)
        end)
    end)
end)
