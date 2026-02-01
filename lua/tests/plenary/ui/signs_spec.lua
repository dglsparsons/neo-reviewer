local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")

describe("neo_reviewer.ui.signs", function()
    local signs
    local config

    before_each(function()
        package.loaded["neo_reviewer.ui.signs"] = nil
        package.loaded["neo_reviewer.config"] = nil

        config = require("neo_reviewer.config")
        config.setup({})
        signs = require("neo_reviewer.ui.signs")
    end)

    after_each(function()
        helpers.clear_all_buffers()
    end)

    describe("place", function()
        it("places add signs at added_lines positions", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 3,
                    kind = "add",
                    added_lines = { 2, 3 },
                    changed_lines = {},
                    deletion_groups = {},
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(2, #extmarks)

            local found_add_sign = false
            for _, mark in ipairs(extmarks) do
                if mark[4].sign_text and vim.trim(mark[4].sign_text) == "+" then
                    found_add_sign = true
                    break
                end
            end
            assert.is_true(found_add_sign)
        end)

        it("places delete signs at deleted_at positions", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 2,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        { anchor_line = 2, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(1, #extmarks)

            local found_delete_sign = false
            for _, mark in ipairs(extmarks) do
                if mark[4].sign_text and vim.trim(mark[4].sign_text) == "-" then
                    found_delete_sign = true
                    break
                end
            end
            assert.is_true(found_delete_sign)
        end)

        it("clamps delete signs past EOF to last line", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 4,
                    end_line = 4,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        { anchor_line = 4, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(1, #extmarks)
            assert.are.equal(2, extmarks[1][2])
        end)

        it("places change signs for change hunks", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 2,
                    kind = "change",
                    added_lines = { 2 },
                    changed_lines = { 2 },
                    deletion_groups = {
                        { anchor_line = 2, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.is_true(#extmarks >= 1)

            local found_change_sign = false
            for _, mark in ipairs(extmarks) do
                if mark[4].sign_text and vim.trim(mark[4].sign_text) == "~" then
                    found_change_sign = true
                    break
                end
            end
            assert.is_true(found_change_sign)
        end)

        it("uses add signs for pure additions within change hunks when changed_lines are provided", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4" })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 4,
                    kind = "change",
                    added_lines = { 2, 3, 4 },
                    changed_lines = { 2 },
                    deletion_groups = {
                        { anchor_line = 2, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(3, #extmarks)

            local change_count = 0
            local add_count = 0
            for _, mark in ipairs(extmarks) do
                local sign = mark[4].sign_text and vim.trim(mark[4].sign_text)
                if sign == "~" then
                    change_count = change_count + 1
                elseif sign == "+" then
                    add_count = add_count + 1
                end
            end

            assert.are.equal(1, change_count)
            assert.are.equal(2, add_count)
        end)

        it("places signs for multiple hunks", function()
            local bufnr = helpers.create_test_buffer({
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
                "line 9",
                "line 10",
            })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 3,
                    kind = "add",
                    added_lines = { 2, 3 },
                    changed_lines = {},
                    deletion_groups = {},
                    old_to_new = {},
                },
                {
                    start_line = 5,
                    end_line = 5,
                    kind = "change",
                    added_lines = { 5 },
                    changed_lines = { 5 },
                    deletion_groups = {
                        { anchor_line = 5, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
                {
                    start_line = 8,
                    end_line = 8,
                    kind = "delete",
                    added_lines = {},
                    changed_lines = {},
                    deletion_groups = {
                        { anchor_line = 8, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.is_true(#extmarks >= 4)
        end)

        it("clears previous signs before placing new ones", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 1,
                    end_line = 1,
                    kind = "add",
                    added_lines = { 1 },
                    changed_lines = {},
                    deletion_groups = {},
                    old_to_new = {},
                },
            })
            local first_count = #helpers.get_extmarks(bufnr, "nr_signs")

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 2,
                    kind = "change",
                    added_lines = { 2 },
                    changed_lines = { 2 },
                    deletion_groups = {},
                    old_to_new = {},
                },
            })
            local second_count = #helpers.get_extmarks(bufnr, "nr_signs")

            assert.are.equal(first_count, second_count)
        end)

        it("does not duplicate delete sign when added_lines already has sign at same position", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 2,
                    end_line = 2,
                    kind = "change",
                    added_lines = { 2 },
                    changed_lines = { 2 },
                    deletion_groups = {
                        { anchor_line = 2, old_lines = {}, old_line_numbers = {} },
                    },
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(1, #extmarks)
        end)

        it("handles nil change blocks gracefully", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, nil)
            end)

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(0, #extmarks)
        end)

        it("handles empty change blocks array", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, {})
            end)

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(0, #extmarks)
        end)

        it("handles change blocks with empty added_lines and deletion_groups", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, {
                    {
                        start_line = 1,
                        end_line = 1,
                        kind = "add",
                        added_lines = {},
                        changed_lines = {},
                        deletion_groups = {},
                        old_to_new = {},
                    },
                })
            end)

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(0, #extmarks)
        end)

        it("respects custom sign configuration", function()
            config.setup({
                signs = {
                    add = "A",
                    delete = "D",
                    change = "C",
                },
            })

            package.loaded["neo_reviewer.ui.signs"] = nil
            signs = require("neo_reviewer.ui.signs")

            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 1,
                    end_line = 1,
                    kind = "add",
                    added_lines = { 1 },
                    changed_lines = {},
                    deletion_groups = {},
                    old_to_new = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            local found_custom_sign = false
            for _, mark in ipairs(extmarks) do
                if mark[4].sign_text and vim.trim(mark[4].sign_text) == "A" then
                    found_custom_sign = true
                    break
                end
            end
            assert.is_true(found_custom_sign)
        end)

        it("skips lines beyond buffer length", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, {
                    {
                        start_line = 1,
                        end_line = 100,
                        kind = "add",
                        added_lines = { 1, 100 },
                        changed_lines = {},
                        deletion_groups = {},
                        old_to_new = {},
                    },
                })
            end)

            local extmarks = helpers.get_extmarks(bufnr, "nr_signs")
            assert.are.equal(1, #extmarks)
        end)
    end)

    describe("clear", function()
        it("removes all signs from buffer", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    start_line = 1,
                    end_line = 2,
                    kind = "add",
                    added_lines = { 1, 2 },
                    changed_lines = {},
                    deletion_groups = {},
                    old_to_new = {},
                },
            })
            assert.is_true(#helpers.get_extmarks(bufnr, "nr_signs") > 0)

            signs.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "nr_signs"))
        end)
    end)
end)
