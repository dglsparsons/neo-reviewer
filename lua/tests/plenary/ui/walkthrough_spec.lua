local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")

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

describe("neo_reviewer.ui.walkthrough", function()
    local walkthrough_ui
    local state
    local original_columns
    local original_lines

    before_each(function()
        original_columns = vim.o.columns
        original_lines = vim.o.lines
        vim.o.columns = 120
        vim.o.lines = 40

        package.loaded["neo_reviewer.ui.walkthrough"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.nav"] = nil
        package.loaded["neo_reviewer.config"] = nil
        package.loaded["neo_reviewer"] = nil
        walkthrough_ui = require("neo_reviewer.ui.walkthrough")
        state = require("neo_reviewer.state")
    end)

    after_each(function()
        vim.o.columns = original_columns
        vim.o.lines = original_lines
        walkthrough_ui.close()
        state.clear_walkthrough()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("shows a loading message while waiting for a walkthrough", function()
        walkthrough_ui.show_loading()

        local loading_bufnr = assert(find_buffer_by_filetype("neo-reviewer-loading"))
        local rendered = vim.api.nvim_buf_get_lines(loading_bufnr, 0, -1, false)
        local combined = table.concat(rendered, "\n")
        assert.is_truthy(combined:find("Ask: generating walkthrough"))
    end)

    it("re-registers the loading preload before closing when plugin state is partial", function()
        local original_plugin = package.loaded["neo_reviewer.plugin"]
        package.preload["neo_reviewer.ui.loading"] = nil
        package.loaded["neo_reviewer.ui.loading"] = nil
        package.loaded["neo_reviewer.plugin"] = {
            register_preloads = function() end,
        }

        local ok, closed = pcall(walkthrough_ui.close)

        package.loaded["neo_reviewer.plugin"] = original_plugin

        assert.is_true(ok)
        assert.is_false(closed)
        assert.is_function(package.preload["neo_reviewer.ui.loading"])
    end)

    it("renders a step navigator and a separate detail pane", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_test.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Test overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Explains the first step",
                    anchors = {
                        { file = "tmp_walkthrough_test.lua", start_line = 1, end_line = 2 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open()

        local detail_bufnr = assert(find_buffer_by_filetype("neo-reviewer-walkthrough"))
        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-walkthrough-nav"))
        local detail = table.concat(vim.api.nvim_buf_get_lines(detail_bufnr, 0, -1, false), "\n")
        local navigator = table.concat(vim.api.nvim_buf_get_lines(nav_bufnr, 0, -1, false), "\n")

        assert.is_truthy(navigator:find("Overview", 1, true))
        assert.is_truthy(navigator:find("Steps (1)", 1, true))
        assert.is_truthy(navigator:find("> 1. Step One", 1, true))

        assert.is_truthy(detail:find("Step 1/1", 1, true))
        assert.is_truthy(detail:find("Step One", 1, true))
        assert.is_truthy(detail:find("Details", 1, true))
        assert.is_truthy(detail:find("Explains the first step", 1, true))
        assert.is_truthy(detail:find("Files In This Step", 1, true))
        assert.is_truthy(detail:find("tmp_walkthrough_test.lua", 1, true))
    end)

    it("highlights the current step anchors", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_test.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Explains the first step",
                    anchors = {
                        { file = "tmp_walkthrough_test.lua", start_line = 2, end_line = 3 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open()

        local extmarks = helpers.get_extmarks(bufnr, "nr_walkthrough")
        assert.is_true(#extmarks > 0)
    end)

    it("uses a muted walkthrough range background highlight", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_highlight.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Highlight test",
                    anchors = {
                        { file = "tmp_walkthrough_highlight.lua", start_line = 1, end_line = 1 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open()

        local extmarks = helpers.get_extmarks(bufnr, "nr_walkthrough")
        assert.are.equal("NRWalkthroughRange", extmarks[1][4].line_hl_group)

        local hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughRange", link = false })
        assert.are.equal(tonumber("31404a", 16), hl.bg)
        assert.is_nil(hl.link)
    end)

    it("overrides a stale walkthrough highlight definition", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_stale.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        vim.api.nvim_set_hl(0, "NRWalkthroughRange", { fg = "#ffffff" })

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Highlight test",
                    anchors = {
                        { file = "tmp_walkthrough_stale.lua", start_line = 1, end_line = 1 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open()

        local hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughRange", link = false })
        assert.are.equal(tonumber("31404a", 16), hl.bg)
    end)

    it("jumps to the first anchor when opening with jump_to_first", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_jump.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Explains the first step",
                    anchors = {
                        { file = "tmp_walkthrough_jump.lua", start_line = 3, end_line = 3 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        helpers.set_cursor(1, 0)
        walkthrough_ui.open({ jump_to_first = true })

        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(3, cursor[1])
    end)

    it("jumps to the first step that has anchors when the first step has none", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_jump2.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Conceptual preface",
                    anchors = {},
                },
                {
                    title = "Step Two",
                    explanation = "Anchored step",
                    anchors = {
                        { file = "tmp_walkthrough_jump2.lua", start_line = 2, end_line = 2 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        helpers.set_cursor(1, 0)
        walkthrough_ui.open({ jump_to_first = true })

        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(2, cursor[1])
    end)

    it("routes next_change to walkthrough steps when open", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_test.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "First step",
                    anchors = {
                        { file = "tmp_walkthrough_test.lua", start_line = 1, end_line = 1 },
                    },
                },
                {
                    title = "Step Two",
                    explanation = "Second step",
                    anchors = {
                        { file = "tmp_walkthrough_test.lua", start_line = 3, end_line = 3 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open()

        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.next_change()

        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(3, cursor[1])
    end)

    it("navigates anchors within a step before advancing to the next step", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_multi_anchor.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Two anchors",
                    anchors = {
                        { file = "tmp_walkthrough_multi_anchor.lua", start_line = 1, end_line = 1 },
                        { file = "tmp_walkthrough_multi_anchor.lua", start_line = 3, end_line = 3 },
                    },
                },
                {
                    title = "Step Two",
                    explanation = "Next step",
                    anchors = {
                        { file = "tmp_walkthrough_multi_anchor.lua", start_line = 5, end_line = 5 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open({ jump_to_first = true })
        local neo_reviewer = require("neo_reviewer")

        neo_reviewer.next_change()
        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(3, cursor[1])

        local walkthrough_bufnr = assert(find_buffer_by_filetype("neo-reviewer-walkthrough"))
        local rendered = vim.api.nvim_buf_get_lines(walkthrough_bufnr, 0, -1, false)
        local combined = table.concat(rendered, "\n")
        assert.is_truthy(combined:find("Step 1/2", 1, true))

        neo_reviewer.next_change()
        cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(5, cursor[1])

        rendered = vim.api.nvim_buf_get_lines(walkthrough_bufnr, 0, -1, false)
        combined = table.concat(rendered, "\n")
        assert.is_truthy(combined:find("Step 2/2", 1, true))
    end)

    it("navigates backwards through anchors before moving to the previous step", function()
        local root = vim.fn.getcwd()
        local file_path = root .. "/tmp_walkthrough_multi_anchor_prev.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Overview",
            steps = {
                {
                    title = "Step One",
                    explanation = "Two anchors",
                    anchors = {
                        { file = "tmp_walkthrough_multi_anchor_prev.lua", start_line = 1, end_line = 1 },
                        { file = "tmp_walkthrough_multi_anchor_prev.lua", start_line = 3, end_line = 3 },
                    },
                },
                {
                    title = "Step Two",
                    explanation = "Next step",
                    anchors = {
                        { file = "tmp_walkthrough_multi_anchor_prev.lua", start_line = 5, end_line = 5 },
                    },
                },
            },
            prompt = "Prompt",
            root = root,
        })

        walkthrough_ui.open({ jump_to_first = true })
        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.next_change()
        neo_reviewer.next_change()

        neo_reviewer.prev_change()
        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(3, cursor[1])

        neo_reviewer.prev_change()
        cursor = vim.api.nvim_win_get_cursor(0)
        assert.are.equal(1, cursor[1])
    end)
end)
