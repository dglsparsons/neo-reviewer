local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")
local fixtures = require("fixtures.mock_pr_data")

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

describe("neo_reviewer Ask walkthrough controls", function()
    local neo_reviewer
    local state
    local walkthrough_ui
    local ai_ui
    local notifications
    local original_lines
    local original_columns

    before_each(function()
        original_lines = vim.o.lines
        original_columns = vim.o.columns
        vim.o.lines = 40
        vim.o.columns = 140

        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.plugin"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.walkthrough"] = nil
        package.loaded["neo_reviewer.ui.ai"] = nil

        require("neo_reviewer.plugin").register_preloads()
        neo_reviewer = require("neo_reviewer")
        state = require("neo_reviewer.state")
        walkthrough_ui = require("neo_reviewer.ui.walkthrough")
        ai_ui = require("neo_reviewer.ui.ai")
        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        vim.o.lines = original_lines
        vim.o.columns = original_columns
        notifications.restore()
        walkthrough_ui.close()
        state.clear_walkthrough()
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("done closes and clears Ask walkthrough sessions", function()
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })
        walkthrough_ui.open()

        assert.is_true(walkthrough_ui.is_open())
        assert.is_not_nil(state.get_walkthrough())

        neo_reviewer.done()

        assert.is_false(walkthrough_ui.is_open())
        assert.is_nil(state.get_walkthrough())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Walkthrough closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("done closes Ask loading window when no walkthrough data exists", function()
        walkthrough_ui.show_loading()
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.done()

        assert.is_false(walkthrough_ui.is_open())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Walkthrough window closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("toggle_ai_feedback toggles Ask walkthrough when no review is active", function()
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })

        assert.is_false(walkthrough_ui.is_open())
        neo_reviewer.toggle_ai_feedback()
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_false(walkthrough_ui.is_open())
    end)

    it("done clears Ask walkthrough even when a review is active", function()
        state.set_local_review(helpers.deep_copy(fixtures.local_diff))
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })
        walkthrough_ui.open()

        assert.is_not_nil(state.get_review())
        assert.is_true(walkthrough_ui.is_open())
        assert.is_not_nil(state.get_walkthrough())

        neo_reviewer.done()

        assert.is_nil(state.get_review())
        assert.is_false(walkthrough_ui.is_open())
        assert.is_nil(state.get_walkthrough())

        local notifs = notifications.get()
        assert.are.equal(1, #notifs)
        assert.matches("Review closed", notifs[1].msg)
        assert.are.equal(vim.log.levels.INFO, notifs[1].level)
    end)

    it("cycles stacked review/Ask visibility in the expected order", function()
        state.set_local_review(helpers.deep_copy(fixtures.local_diff))
        state.set_ai_analysis({
            overview = "Review overview",
            steps = {},
        })
        state.set_walkthrough({
            mode = "walkthrough",
            overview = "Walkthrough overview",
            steps = {},
            prompt = "Prompt",
            root = cwd,
        })

        ai_ui.open()
        walkthrough_ui.open()
        assert.is_true(ai_ui.is_open())
        assert.is_true(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_false(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(ai_ui.is_open())
        assert.is_false(walkthrough_ui.is_open())

        neo_reviewer.toggle_ai_feedback()
        assert.is_true(walkthrough_ui.is_open())
        assert.is_true(ai_ui.is_open())
    end)

    it("uses a muted Ask highlight palette", function()
        local file_path = cwd .. "/tmp_walkthrough_highlight.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2", "line 3" })
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
                        { file = "tmp_walkthrough_highlight.lua", start_line = 1, end_line = 2 },
                    },
                },
            },
            prompt = "Prompt",
            root = cwd,
        })

        walkthrough_ui.open()

        local nav_bufnr = assert(find_buffer_by_filetype("neo-reviewer-walkthrough-nav"))
        local file_extmarks = helpers.get_extmarks(bufnr, "nr_walkthrough")
        assert.are.equal("NRWalkthroughRange", file_extmarks[1][4].line_hl_group)

        local nav_extmarks = helpers.get_extmarks(nav_bufnr, "nr_walkthrough")
        local active_found = false
        for _, extmark in ipairs(nav_extmarks) do
            if extmark[4].line_hl_group == "NRWalkthroughActiveStep" then
                active_found = true
                break
            end
        end
        assert.is_true(active_found)

        local range_hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughRange", link = false })
        assert.are.equal(tonumber("31404a", 16), range_hl.bg)
        assert.is_nil(range_hl.link)

        local active_hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughActiveStep", link = false })
        assert.are.equal(tonumber("28343d", 16), active_hl.bg)
        assert.is_nil(active_hl.link)
    end)

    it("overrides stale Ask highlight definitions", function()
        local file_path = cwd .. "/tmp_walkthrough_stale.lua"
        local bufnr = helpers.create_test_buffer({ "line 1", "line 2" })
        vim.api.nvim_buf_set_name(bufnr, file_path)
        vim.bo[bufnr].buftype = ""

        vim.api.nvim_set_hl(0, "NRWalkthroughActiveStep", { fg = "#ffffff" })
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
            root = cwd,
        })

        walkthrough_ui.open()

        local range_hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughRange", link = false })
        assert.are.equal(tonumber("31404a", 16), range_hl.bg)

        local active_hl = vim.api.nvim_get_hl(0, { name = "NRWalkthroughActiveStep", link = false })
        assert.are.equal(tonumber("28343d", 16), active_hl.bg)
    end)
end)
