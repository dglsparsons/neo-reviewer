local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

local function setup_review(pr_data)
    local state = require("neo_reviewer.state")
    local review_data = helpers.deep_copy(pr_data)
    state.set_review(review_data)
    local review = state.get_review()
    review.url = "https://github.com/owner/repo/pull/789"
    return review, state
end

describe("neo_reviewer.ui.ai", function()
    local ai_ui

    local function find_walkthrough_buffer()
        local fallback = nil
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].filetype == "neo-reviewer-ai" then
                if vim.fn.bufwinid(buf) ~= -1 then
                    return buf
                end
                fallback = fallback or buf
            end
        end
        return fallback
    end

    before_each(function()
        package.loaded["neo_reviewer.ui.ai"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.nav"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.config"] = nil
        ai_ui = require("neo_reviewer.ui.ai")
    end)

    after_each(function()
        local state = require("neo_reviewer.state")
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("renders overview and step content in the walkthrough buffer", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "Test overview",
            steps = {
                {
                    title = "First step",
                    explanation = "Explains the first change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        local file = review.files[1]
        local lines = vim.split(file.content, "\n")
        local bufnr = helpers.create_test_buffer(lines)
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.show_details()

        local walkthrough_bufnr = find_walkthrough_buffer()

        assert.is_not_nil(walkthrough_bufnr)
        ---@cast walkthrough_bufnr integer
        local rendered = vim.api.nvim_buf_get_lines(walkthrough_bufnr, 0, -1, false)
        local combined = table.concat(rendered, "\n")
        assert.is_truthy(combined:find("Overview:"))
        assert.is_truthy(combined:find("Step 1/1: First step"))
        assert.is_truthy(combined:find("Explains the first change"))
    end)

    it("syncs walkthrough step when navigating change blocks", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "Test overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "First change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
                {
                    title = "Step Two",
                    explanation = "Second change",
                    change_blocks = { { file = "test.lua", change_block_index = 1 } },
                },
            },
        })

        local file = review.files[1]
        local lines = vim.split(file.content, "\n")
        local bufnr = helpers.create_test_buffer(lines)
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.show_details()

        local nav = require("neo_reviewer.ui.nav")
        helpers.set_cursor(3)
        nav.next_change(false)

        local walkthrough_bufnr = find_walkthrough_buffer()

        assert.is_not_nil(walkthrough_bufnr)
        ---@cast walkthrough_bufnr integer
        local rendered = vim.api.nvim_buf_get_lines(walkthrough_bufnr, 0, -1, false)
        local combined = table.concat(rendered, "\n")
        assert.is_truthy(combined:find("Step 2/2: Step Two"))
    end)
end)
