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

local function find_buffer_by_filetype(filetype)
    local fallback = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == filetype then
            if vim.fn.bufwinid(buf) ~= -1 then
                return buf
            end
            fallback = fallback or buf
        end
    end
    return fallback
end

describe("neo_reviewer.ui.ai", function()
    local ai_ui
    local original_columns
    local original_lines

    before_each(function()
        original_columns = vim.o.columns
        original_lines = vim.o.lines
        vim.o.columns = 100
        vim.o.lines = 40

        package.loaded["neo_reviewer.ui.ai"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.nav"] = nil
        package.loaded["neo_reviewer.ui.buffer"] = nil
        package.loaded["neo_reviewer.config"] = nil
        ai_ui = require("neo_reviewer.ui.ai")
    end)

    after_each(function()
        vim.o.columns = original_columns
        vim.o.lines = original_lines

        local state = require("neo_reviewer.state")
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("renders a step navigator and a separate detail pane", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "Test overview\nSecond line",
            steps = {
                {
                    title = "First step",
                    explanation = "Explains the first change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        local file = review.files[1]
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.show_details()

        local detail_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai"))
        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))

        local detail = table.concat(vim.api.nvim_buf_get_lines(detail_bufnr, 0, -1, false), "\n")
        local navigator = table.concat(vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false), "\n")

        assert.is_truthy(navigator:find("Overview", 1, true))
        assert.is_truthy(navigator:find("Steps (1)", 1, true))
        assert.is_truthy(navigator:find("> 1. First step", 1, true))

        assert.is_truthy(detail:find("Step 1/1", 1, true))
        assert.is_truthy(detail:find("First step", 1, true))
        assert.is_truthy(detail:find("Details", 1, true))
        assert.is_truthy(detail:find("Explains the first change", 1, true))
        assert.is_truthy(detail:find("Files In This Step", 1, true))
        assert.is_truthy(detail:find("%- test.lua"))
    end)

    it("syncs the active step across navigator and detail panes", function()
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
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.show_details()

        local nav = require("neo_reviewer.ui.nav")
        helpers.set_cursor(3)
        nav.next_change(false)

        local detail_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai"))
        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local detail = table.concat(vim.api.nvim_buf_get_lines(detail_bufnr, 0, -1, false), "\n")
        local navigator = table.concat(vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false), "\n")

        assert.is_truthy(detail:find("Step 2/2", 1, true))
        assert.is_truthy(detail:find("Step Two", 1, true))
        assert.is_truthy(navigator:find("> 2. Step Two", 1, true))
    end)

    it("lets the user jump to a step from the navigator pane", function()
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
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.open()

        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local nav_winid = vim.fn.bufwinid(nav_bufnr)
        assert.is_true(nav_winid ~= -1)
        vim.api.nvim_set_current_win(nav_winid)

        local nav_lines = vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false)
        local target_line = nil
        for index, line in ipairs(nav_lines) do
            if line:find("2. Step Two", 1, true) then
                target_line = index
                break
            end
        end

        assert.is_not_nil(target_line)
        ---@cast target_line integer
        helpers.set_cursor(target_line, 0)

        ai_ui.select_current_step()

        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(10, cursor[1])
    end)

    it("keeps 50 characters of overview content on one line by default when the layout allows", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "12345678901234567890123456789012345678901234567890",
            steps = {
                {
                    title = "First step",
                    explanation = "Explains the first change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        local file = review.files[1]
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.open()

        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local nav_winid = vim.fn.bufwinid(nav_bufnr)
        assert.is_true(nav_winid ~= -1)

        local nav_lines = vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false)

        assert.are.equal(52, vim.api.nvim_win_get_width(nav_winid))
        assert.are.equal("12345678901234567890123456789012345678901234567890", nav_lines[2])
        assert.are.equal("Steps (1)", nav_lines[4])
    end)

    it("wraps long step titles and omits navigator file counts", function()
        local review, state = setup_review(fixtures.navigation_pr)
        require("neo_reviewer.config").setup({
            ai = {
                walkthrough_window = {
                    step_list_width = 24,
                },
            },
        })

        state.set_ai_analysis({
            overview = "Test overview\nSecond line\nThird line",
            steps = {
                {
                    title = "Add server-side Usage aggregation and persistence for job scheduling",
                    explanation = "Explains the first change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
                {
                    title = "Wire Usage into the existing response payload",
                    explanation = "Explains the second change",
                    change_blocks = { { file = "test.lua", change_block_index = 1 } },
                },
            },
        })

        local file = review.files[1]
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.open()

        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local nav_winid = vim.fn.bufwinid(nav_bufnr)
        assert.is_true(nav_winid ~= -1)
        local nav_lines = vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false)
        local navigator = table.concat(nav_lines, "\n")

        local first_step_line = nil
        for index, line in ipairs(nav_lines) do
            if line:find("> 1.", 1, true) then
                first_step_line = index
                break
            end
        end

        assert.is_not_nil(first_step_line)
        ---@cast first_step_line integer
        assert.is_not_nil(nav_lines[first_step_line + 1])
        assert.is_nil(nav_lines[first_step_line + 1]:find("^%s*2%."))
        assert.is_nil(nav_lines[first_step_line + 1]:find("^%s*$"))
        assert.is_nil(navigator:find("1 file", 1, true))
        assert.is_nil(navigator:find("Third line", 1, true))

        vim.api.nvim_set_current_win(nav_winid)
        helpers.set_cursor(first_step_line + 1, 0)
        ai_ui.select_current_step()

        local detail_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai"))
        local detail = table.concat(vim.api.nvim_buf_get_lines(detail_bufnr, 0, -1, false), "\n")
        assert.is_truthy(detail:find("Step 1/2", 1, true))
    end)

    it("pre-wraps overview text without enabling navigator wrap", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "This overview line is intentionally long so the navigator needs wrapping instead of truncation.",
            steps = {
                {
                    title = "First step",
                    explanation = "Explains the first change",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        local file = review.files[1]
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        require("neo_reviewer.config").setup({
            ai = {
                walkthrough_window = {
                    step_list_width = 24,
                },
            },
        })

        ai_ui.open()

        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local nav_winid = vim.fn.bufwinid(nav_bufnr)
        assert.is_true(nav_winid ~= -1)
        assert.is_false(vim.wo[nav_winid].wrap)

        local nav_lines = vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false)
        local navigator = table.concat(nav_lines, "\n")

        local steps_heading = nil
        for index, line in ipairs(nav_lines) do
            if line == "Steps (1)" then
                steps_heading = index
                break
            end
        end

        assert.is_not_nil(steps_heading)
        ---@cast steps_heading integer
        assert.is_true(steps_heading > 4)
        assert.is_truthy(navigator:find("truncation.", 1, true))
    end)

    it("refreshes an open walkthrough without resizing the existing layout when requested", function()
        local review, state = setup_review(fixtures.navigation_pr)
        state.set_ai_analysis({
            overview = "Initial overview",
            steps = {
                {
                    title = "Initial step",
                    explanation = "Short explanation",
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        local file = review.files[1]
        local bufnr = helpers.create_test_buffer(vim.split(file.content, "\n"))
        vim.api.nvim_buf_set_var(bufnr, "nr_file", file)
        vim.api.nvim_buf_set_var(bufnr, "nr_pr_url", review.url)
        state.mark_buffer_applied(bufnr)
        require("neo_reviewer.ui.buffer").place_change_block_marks(bufnr, file)

        ai_ui.open()

        local detail_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai"))
        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-ai-nav"))
        local detail_winid = vim.fn.bufwinid(detail_bufnr)
        local nav_winid = vim.fn.bufwinid(nav_bufnr)

        vim.api.nvim_win_set_height(detail_winid, 3)
        vim.api.nvim_win_set_width(nav_winid, 24)

        state.set_ai_analysis({
            overview = "Updated overview",
            steps = {
                {
                    title = "Updated step title that would normally trigger a wider navigator render",
                    explanation = table.concat({
                        "Updated explanation line 1",
                        "Updated explanation line 2",
                        "Updated explanation line 3",
                    }, "\n"),
                    change_blocks = { { file = "test.lua", change_block_index = 0 } },
                },
            },
        })

        ai_ui.open({ preserve_layout = true })

        assert.are.equal(3, vim.api.nvim_win_get_height(detail_winid))
        assert.are.equal(24, vim.api.nvim_win_get_width(nav_winid))

        local detail = table.concat(vim.api.nvim_buf_get_lines(detail_bufnr, 0, -1, false), "\n")
        assert.is_truthy(detail:find("Updated step title", 1, true))
        assert.is_truthy(detail:find("Updated explanation line 3", 1, true))
    end)
end)
