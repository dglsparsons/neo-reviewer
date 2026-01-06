local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")

describe("greviewer.ui.signs", function()
    local signs
    local config

    before_each(function()
        package.loaded["greviewer.ui.signs"] = nil
        package.loaded["greviewer.config"] = nil

        config = require("greviewer.config")
        config.setup({})
        signs = require("greviewer.ui.signs")
    end)

    after_each(function()
        helpers.clear_all_buffers()
    end)

    describe("place", function()
        it("places add signs at added_lines positions", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })

            signs.place(bufnr, {
                {
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 2, 3 },
                    deleted_at = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
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
                    hunk_type = "delete",
                    old_lines = { "deleted line" },
                    added_lines = {},
                    deleted_at = { 2 },
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
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

        it("places change signs for change hunks", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    hunk_type = "change",
                    old_lines = { "old line" },
                    added_lines = { 2 },
                    deleted_at = { 2 },
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
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
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 2, 3 },
                    deleted_at = {},
                },
                {
                    hunk_type = "change",
                    old_lines = { "old" },
                    added_lines = { 5 },
                    deleted_at = { 5 },
                },
                {
                    hunk_type = "delete",
                    old_lines = { "deleted" },
                    added_lines = {},
                    deleted_at = { 8 },
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
            assert.is_true(#extmarks >= 4)
        end)

        it("clears previous signs before placing new ones", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 1 },
                    deleted_at = {},
                },
            })
            local first_count = #helpers.get_extmarks(bufnr, "greviewer_signs")

            signs.place(bufnr, {
                {
                    hunk_type = "change",
                    old_lines = { "old" },
                    added_lines = { 2 },
                    deleted_at = {},
                },
            })
            local second_count = #helpers.get_extmarks(bufnr, "greviewer_signs")

            assert.are.equal(first_count, second_count)
        end)

        it("does not duplicate delete sign when added_lines already has sign at same position", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    hunk_type = "change",
                    old_lines = { "old" },
                    added_lines = { 2 },
                    deleted_at = { 2 },
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
            assert.are.equal(1, #extmarks)
        end)

        it("handles nil hunks gracefully", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, nil)
            end)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
            assert.are.equal(0, #extmarks)
        end)

        it("handles empty hunks array", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, {})
            end)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
            assert.are.equal(0, #extmarks)
        end)

        it("handles hunks with empty added_lines and deleted_at", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })

            assert.has_no_errors(function()
                signs.place(bufnr, {
                    {
                        hunk_type = "add",
                        old_lines = {},
                        added_lines = {},
                        deleted_at = {},
                    },
                })
            end)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
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

            package.loaded["greviewer.ui.signs"] = nil
            signs = require("greviewer.ui.signs")

            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 1 },
                    deleted_at = {},
                },
            })

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
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
                        hunk_type = "add",
                        old_lines = {},
                        added_lines = { 1, 100 },
                        deleted_at = {},
                    },
                })
            end)

            local extmarks = helpers.get_extmarks(bufnr, "greviewer_signs")
            assert.are.equal(1, #extmarks)
        end)
    end)

    describe("clear", function()
        it("removes all signs from buffer", function()
            local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })

            signs.place(bufnr, {
                {
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 1, 2 },
                    deleted_at = {},
                },
            })
            assert.is_true(#helpers.get_extmarks(bufnr, "greviewer_signs") > 0)

            signs.clear(bufnr)
            assert.are.equal(0, #helpers.get_extmarks(bufnr, "greviewer_signs"))
        end)
    end)
end)
