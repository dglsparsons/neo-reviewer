local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("greviewer.ui.buffer", function()
    local buffer

    before_each(function()
        package.loaded["greviewer.ui.buffer"] = nil

        buffer = require("greviewer.ui.buffer")
    end)

    after_each(function()
        helpers.clear_all_buffers()
    end)

    -- Helper to set up a buffer with greviewer variables (simulates what init.apply_overlay_to_buffer does)
    local function setup_review_buffer(file, pr_url)
        local lines = {}
        if file.content then
            lines = vim.split(file.content, "\n")
        else
            lines = { "-- placeholder --" }
        end

        local bufnr = helpers.create_test_buffer(lines)
        vim.api.nvim_buf_set_var(bufnr, "greviewer_file", file)
        vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", pr_url)
        return bufnr
    end

    describe("get_current_file_from_buffer", function()
        it("returns file data from buffer variable", function()
            local file = helpers.deep_copy(fixtures.simple_pr.files[1])
            setup_review_buffer(file, "https://github.com/owner/repo/pull/123")

            local result = buffer.get_current_file_from_buffer()
            assert.is_not_nil(result)
            assert.are.equal("src/main.lua", result.path)
        end)

        it("returns full file data including hunks", function()
            local file = helpers.deep_copy(fixtures.simple_pr.files[1])
            setup_review_buffer(file, "https://github.com/owner/repo/pull/123")

            local result = buffer.get_current_file_from_buffer()
            assert.is_not_nil(result.hunks)
            assert.are.equal(1, #result.hunks)
            assert.are.equal("change", result.hunks[1].hunk_type)
        end)

        it("returns nil for non-review buffer", function()
            helpers.create_test_buffer({ "not", "a", "review" })

            local file = buffer.get_current_file_from_buffer()
            assert.is_nil(file)
        end)

        it("returns nil for buffer without greviewer_file var", function()
            local bufnr = helpers.create_test_buffer({ "some", "content" })
            vim.api.nvim_buf_set_var(bufnr, "greviewer_pr_url", "https://example.com")

            local file = buffer.get_current_file_from_buffer()
            assert.is_nil(file)
        end)
    end)

    describe("get_pr_url_from_buffer", function()
        it("returns PR URL from buffer variable", function()
            local file = helpers.deep_copy(fixtures.simple_pr.files[1])
            setup_review_buffer(file, "https://github.com/owner/repo/pull/123")

            local url = buffer.get_pr_url_from_buffer()
            assert.are.equal("https://github.com/owner/repo/pull/123", url)
        end)

        it("returns nil for non-review buffer", function()
            helpers.create_test_buffer({ "not", "a", "review" })

            local url = buffer.get_pr_url_from_buffer()
            assert.is_nil(url)
        end)

        it("returns nil for buffer without greviewer_pr_url var", function()
            local bufnr = helpers.create_test_buffer({ "some", "content" })
            vim.api.nvim_buf_set_var(bufnr, "greviewer_file", { path = "test.lua" })

            local url = buffer.get_pr_url_from_buffer()
            assert.is_nil(url)
        end)
    end)

    describe("both functions work together", function()
        it("can retrieve both file and URL from same buffer", function()
            local file = helpers.deep_copy(fixtures.multi_file_pr.files[1])
            local pr_url = "https://github.com/owner/repo/pull/456"
            setup_review_buffer(file, pr_url)

            local result_file = buffer.get_current_file_from_buffer()
            local result_url = buffer.get_pr_url_from_buffer()

            assert.is_not_nil(result_file)
            assert.is_not_nil(result_url)
            assert.are.equal("src/foo.lua", result_file.path)
            assert.are.equal(pr_url, result_url)
        end)
    end)
end)
