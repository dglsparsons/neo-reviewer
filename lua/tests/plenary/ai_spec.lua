local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

describe("neo_reviewer.ai", function()
    local ai

    before_each(function()
        package.loaded["neo_reviewer.ai"] = nil
        package.loaded["neo_reviewer.config"] = nil
        package.loaded["neo_reviewer.state"] = nil
        ai = require("neo_reviewer.ai")
    end)

    describe("build_prompt", function()
        it("includes PR title", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Add validation", description = "Some description" },
                files = {},
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("Add validation"))
        end)

        it("includes PR description", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Title", description = "This is the PR description" },
                files = {},
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("This is the PR description"))
        end)

        it("handles missing description", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Title" },
                files = {},
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("No description provided"))
        end)

        it("includes file list with status", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Title" },
                files = {
                    { path = "src/main.rs", status = "modified", additions = 10, deletions = 5, change_blocks = {} },
                    { path = "src/new.rs", status = "added", additions = 50, deletions = 0, change_blocks = {} },
                },
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("%[~%] src/main.rs"))
            assert.is_truthy(prompt:find("%[%+%] src/new.rs"))
        end)

        it("includes instruction for JSON output", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Title" },
                files = {},
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("Return ONLY valid JSON"))
            assert.is_truthy(prompt:find('"overview"'))
            assert.is_truthy(prompt:find('"steps"'))
        end)

        it("includes repo root and file-reading rules", function()
            ---@type NRReview
            local review = {
                review_type = "pr",
                git_root = "/tmp/repo",
                pr = { number = 1, title = "Title", description = "Description" },
                files = {},
                files_by_path = {},
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            local prompt = ai.build_prompt(review)

            assert.is_truthy(prompt:find("git repository at: /tmp/repo", 1, true))
            assert.is_truthy(prompt:find("Read files directly from disk", 1, true))
        end)
    end)

    describe("coverage enforcement", function()
        local function build_review()
            local file = {
                path = "test.lua",
                status = "modified",
                additions = 3,
                deletions = 0,
                change_blocks = {
                    {
                        start_line = 1,
                        end_line = 1,
                        kind = "add",
                        added_lines = { 1 },
                        changed_lines = {},
                        deletion_groups = {},
                        old_to_new = {},
                    },
                    {
                        start_line = 3,
                        end_line = 3,
                        kind = "add",
                        added_lines = { 3 },
                        changed_lines = {},
                        deletion_groups = {},
                        old_to_new = {},
                    },
                    {
                        start_line = 5,
                        end_line = 5,
                        kind = "add",
                        added_lines = { 5 },
                        changed_lines = {},
                        deletion_groups = {},
                        old_to_new = {},
                    },
                },
            }

            ---@type NRReview
            local review = {
                review_type = "pr",
                pr = { number = 1, title = "Test", description = "Coverage" },
                files = { file },
                files_by_path = {
                    ["test.lua"] = file,
                },
                comments = {},
                current_file_idx = 1,
                expanded_changes = {},
                applied_buffers = {},
                overlays_visible = true,
            }

            return review
        end

        it("appends placeholders for missing change_blocks", function()
            local review = build_review()
            ---@type NRAIAnalysis
            local analysis = {
                overview = "Overview",
                steps = {
                    {
                        title = "Step One",
                        explanation = "Covers first hunk",
                        change_blocks = {
                            { file = "test.lua", change_block_index = 0 },
                        },
                    },
                },
            }

            local updated = ai.ensure_full_coverage(review, analysis)

            assert.are.equal(3, #updated.steps)
            assert.are.equal("Uncovered change: test.lua", updated.steps[2].title)
            assert.are.same({ file = "test.lua", change_block_index = 1 }, updated.steps[2].change_blocks[1])
            assert.are.same({ file = "test.lua", change_block_index = 2 }, updated.steps[3].change_blocks[1])
        end)

        it("does not add placeholders when all change_blocks covered", function()
            local review = build_review()
            ---@type NRAIAnalysis
            local analysis = {
                overview = "Overview",
                steps = {
                    {
                        title = "Hunk 0",
                        explanation = "First",
                        change_blocks = { { file = "test.lua", change_block_index = 0 } },
                    },
                    {
                        title = "Hunk 1",
                        explanation = "Second",
                        change_blocks = { { file = "test.lua", change_block_index = 1 } },
                    },
                    {
                        title = "Hunk 2",
                        explanation = "Third",
                        change_blocks = { { file = "test.lua", change_block_index = 2 } },
                    },
                },
            }

            local updated = ai.ensure_full_coverage(review, analysis)

            assert.are.equal(3, #updated.steps)
        end)

        it("builds missing prompt with only missing change_blocks", function()
            local review = build_review()
            local missing = {
                { file = "test.lua", change_block_index = 2 },
            }

            local prompt = ai.build_missing_prompt(review, missing)

            assert.is_truthy(prompt:find("@@ change_block 2 @@"))
            assert.is_nil(prompt:find("@@ change_block 0 @@"))
            assert.is_nil(prompt:find("@@ change_block 1 @@"))
        end)
    end)
end)

describe("neo_reviewer.config AI defaults", function()
    local config

    before_each(function()
        package.loaded["neo_reviewer.config"] = nil
        config = require("neo_reviewer.config")
    end)

    it("has AI disabled by default", function()
        assert.is_false(config.values.ai.enabled)
    end)

    it("has default model", function()
        assert.are.equal("gpt-5.2-codex", config.values.ai.model)
    end)

    it("has default command", function()
        assert.are.equal("codex", config.values.ai.command)
    end)

    it("has default reasoning effort", function()
        assert.are.equal("medium", config.values.ai.reasoning_effort)
    end)

    it("has walkthrough window defaults", function()
        assert.are.equal(0, config.values.ai.walkthrough_window.height)
        assert.is_false(config.values.ai.walkthrough_window.focus_on_open)
    end)

    it("can override AI settings", function()
        config.setup({
            ai = {
                enabled = true,
                model = "custom/model",
            },
        })

        assert.is_true(config.values.ai.enabled)
        assert.are.equal("custom/model", config.values.ai.model)
        assert.are.equal("codex", config.values.ai.command)
    end)
end)

describe("neo_reviewer.config build_ai_command", function()
    local config

    before_each(function()
        package.loaded["neo_reviewer.config"] = nil
        config = require("neo_reviewer.config")
    end)

    it("builds codex exec args with reasoning effort", function()
        local spec = config.build_ai_command("Explain this")

        assert.are.equal("codex", spec.command)
        assert.is_nil(spec.writer)
        assert.are.same(
            { "exec", "--model", "gpt-5.2-codex", "--config", 'model_reasoning_effort="medium"', "Explain this" },
            spec.args
        )
    end)

    it("builds opencode args using stdin writer", function()
        config.setup({
            ai = {
                command = "opencode",
                model = "custom/model",
            },
        })

        local spec = config.build_ai_command("Explain this")

        assert.are.equal("opencode", spec.command)
        assert.are.same({ "run", "--model", "custom/model" }, spec.args)
        assert.are.equal("Explain this", spec.writer)
    end)
end)

describe("neo_reviewer.state AI analysis", function()
    local state

    before_each(function()
        package.loaded["neo_reviewer.state"] = nil
        state = require("neo_reviewer.state")
    end)

    after_each(function()
        state.clear_review()
    end)

    it("returns nil when no review active", function()
        assert.is_nil(state.get_ai_analysis())
    end)

    it("returns nil when review has no analysis", function()
        state.set_review({
            pr = { number = 1, title = "Test" },
            files = {},
        })

        assert.is_nil(state.get_ai_analysis())
    end)

    it("can set and get AI analysis", function()
        state.set_review({
            pr = { number = 1, title = "Test" },
            files = {},
        })

        ---@type NRAIAnalysis
        local analysis = {
            overview = "Test overview",
            steps = {
                {
                    title = "Step 1",
                    explanation = "Test context for reviewer",
                    change_blocks = {
                        { file = "test.lua", change_block_index = 0 },
                    },
                },
            },
        }

        state.set_ai_analysis(analysis)

        local retrieved = state.get_ai_analysis()
        assert.is_not_nil(retrieved)
        assert.are.equal("Test overview", retrieved.overview)
        assert.are.equal(1, #retrieved.steps)
        assert.are.equal("Step 1", retrieved.steps[1].title)
    end)

    it("clears AI analysis when review is cleared", function()
        state.set_review({
            pr = { number = 1, title = "Test" },
            files = {},
        })

        state.set_ai_analysis({
            overview = "Test overview",
            steps = {},
        })

        state.clear_review()

        assert.is_nil(state.get_ai_analysis())
    end)
end)
