local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path
local helpers = require("plenary.helpers")
local stub = require("luassert.stub")

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

        it("allows steps to group related change blocks", function()
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

            assert.is_truthy(prompt:find("Each step must include one or more change blocks", 1, true))
            assert.is_truthy(prompt:find("Group related change blocks into the same step", 1, true))
            assert.is_truthy(prompt:find("Do not return steps with empty change_blocks", 1, true))
        end)

        it("asks for reviewer-friendly grouping and standalone step titles", function()
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

            assert.is_truthy(prompt:find("Think like a reviewer guide", 1, true))
            assert.is_truthy(
                prompt:find("Use titles that still make sense when shown alone in a narrow step list", 1, true)
            )
            assert.is_truthy(prompt:find('Avoid filler like "This matters because"', 1, true))
            assert.is_truthy(prompt:find("Start with the concrete change", 1, true))
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
            assert.is_truthy(prompt:find("Added lines and context lines in the diff are placeholders", 1, true))
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

        it("preserves grouped steps while deduplicating change_blocks", function()
            local review = build_review()
            ---@type NRAIAnalysis
            local analysis = {
                overview = "Overview",
                steps = {
                    {
                        title = "Combined",
                        explanation = "Covers first and second hunks",
                        change_blocks = {
                            { file = "test.lua", change_block_index = 0 },
                            { file = "test.lua", change_block_index = 1 },
                            { file = "test.lua", change_block_index = 1 },
                        },
                    },
                    {
                        title = "No anchor",
                        explanation = "Cross-cutting detail",
                        change_blocks = {},
                    },
                    {
                        title = "Duplicate",
                        explanation = "Repeats first hunk",
                        change_blocks = {
                            { file = "test.lua", change_block_index = 0 },
                        },
                    },
                },
            }

            local updated = ai.ensure_full_coverage(review, analysis)

            assert.are.equal(2, #updated.steps)
            assert.are.equal("Combined", updated.steps[1].title)
            assert.are.equal(2, #updated.steps[1].change_blocks)
            assert.are.same({ file = "test.lua", change_block_index = 0 }, updated.steps[1].change_blocks[1])
            assert.are.same({ file = "test.lua", change_block_index = 1 }, updated.steps[1].change_blocks[2])
            assert.are.same({ file = "test.lua", change_block_index = 2 }, updated.steps[2].change_blocks[1])
            assert.are.equal("Uncovered change: test.lua", updated.steps[2].title)
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
    end)

    describe("analyze_pr", function()
        local Job
        local job_instance

        before_each(function()
            Job = require("plenary.job")
            job_instance = {
                start = function() end,
            }

            stub(Job, "new", function(_, opts)
                job_instance._opts = opts
                return job_instance
            end)
        end)

        after_each(function()
            Job.new:revert()
        end)

        it("uses one AI response and appends placeholders for uncovered change_blocks", function()
            local file = {
                path = "test.lua",
                status = "modified",
                additions = 2,
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
                },
            }

            ---@type NRReview
            local review = {
                review_type = "pr",
                git_root = "/tmp/repo",
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

            local received_analysis
            local received_err
            ai.analyze_pr(review, function(analysis, err)
                received_analysis = analysis
                received_err = err
            end)

            assert.stub(Job.new).was_called(1)

            local on_stdout = job_instance._opts.on_stdout
            local on_exit = job_instance._opts.on_exit
            on_stdout(
                nil,
                [[{"overview":"Overview","steps":[{"title":"Step One","explanation":"Direct summary.","change_blocks":[{"file":"test.lua","change_block_index":0}]}]}]]
            )
            on_exit(nil, 0)

            vim.wait(100, function()
                return received_analysis ~= nil or received_err ~= nil
            end)

            assert.is_nil(received_err)
            assert.is_not_nil(received_analysis)
            ---@cast received_analysis NRAIAnalysis
            assert.are.equal(2, #received_analysis.steps)
            assert.are.equal("Uncovered change: test.lua", received_analysis.steps[2].title)
            assert.are.same({ file = "test.lua", change_block_index = 1 }, received_analysis.steps[2].change_blocks[1])
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
        assert.are.equal("gpt-5.3-codex", config.values.ai.model)
    end)

    it("has default command", function()
        assert.are.equal("codex", config.values.ai.command)
    end)

    it("has default reasoning effort", function()
        assert.are.equal("low", config.values.ai.reasoning_effort)
    end)

    it("has walkthrough window defaults", function()
        assert.are.equal(0, config.values.ai.walkthrough_window.height)
        assert.is_false(config.values.ai.walkthrough_window.focus_on_open)
        assert.are.equal(52, config.values.ai.walkthrough_window.step_list_width)
    end)

    it("has Neo-tree defaults", function()
        assert.is_false(config.values.neo_tree.open_on_review)
        assert.are.equal("left", config.values.neo_tree.position)
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
            { "exec", "--model", "gpt-5.3-codex", "--config", 'model_reasoning_effort="low"', "Explain this" },
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

describe("neo_reviewer.neotree", function()
    local captured
    local original_bufnr

    before_each(function()
        package.loaded["neo_reviewer.plugin"] = nil
        package.loaded["neo_reviewer.neotree"] = nil
        package.loaded["neo_reviewer.config"] = nil
        package.loaded["neo-tree.command"] = nil
        package.loaded["neo-tree.sources.manager"] = nil

        require("neo_reviewer.plugin").register_preloads()
        captured = {}
        original_bufnr = vim.api.nvim_get_current_buf()
    end)

    after_each(function()
        package.loaded["neo-tree.command"] = nil
        package.loaded["neo-tree.sources.manager"] = nil
        if vim.api.nvim_buf_is_valid(original_bufnr) then
            vim.api.nvim_set_current_buf(original_bufnr)
        end
    end)

    it("opens the review source when configured to open on review", function()
        package.loaded["neo-tree.command"] = {
            execute = function(opts)
                captured.execute = opts
            end,
        }

        local config = require("neo_reviewer.config")
        config.setup({
            neo_tree = {
                open_on_review = true,
                position = "right",
            },
        })

        local neotree = require("neo_reviewer.neotree")

        assert.is_true(neotree.on_review_changed())
        assert.are.same({ source = "review", position = "right" }, captured.execute)
    end)

    it("refreshes the review source when it is already open", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        vim.bo[bufnr].filetype = "neo-tree"
        vim.b[bufnr].neo_tree_source = "review"

        package.loaded["neo-tree.sources.manager"] = {
            get_state = function()
                return { winid = vim.api.nvim_get_current_win() }
            end,
            refresh = function(source_name)
                captured.refresh = source_name
            end,
        }

        local config = require("neo_reviewer.config")
        config.setup({
            neo_tree = {
                open_on_review = false,
            },
        })

        local neotree = require("neo_reviewer.neotree")

        assert.is_true(neotree.on_review_changed())
        assert.are.equal("review", captured.refresh)
    end)

    it("refreshes instead of reopening when open_on_review is enabled and the tree is already open", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        vim.bo[bufnr].filetype = "neo-tree"
        vim.b[bufnr].neo_tree_source = "review"

        package.loaded["neo-tree.command"] = {
            execute = function(opts)
                captured.execute = opts
            end,
        }
        package.loaded["neo-tree.sources.manager"] = {
            get_state = function()
                return { winid = vim.api.nvim_get_current_win() }
            end,
            refresh = function(source_name)
                captured.refresh = source_name
            end,
        }

        local config = require("neo_reviewer.config")
        config.setup({
            neo_tree = {
                open_on_review = true,
                position = "right",
            },
        })

        local neotree = require("neo_reviewer.neotree")

        assert.is_true(neotree.on_review_changed())
        assert.are.equal("review", captured.refresh)
        assert.is_nil(captured.execute)
    end)

    it("does not treat another Neo-tree source as an open review tree", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        vim.bo[bufnr].filetype = "neo-tree"
        vim.b[bufnr].neo_tree_source = "filesystem"

        package.loaded["neo-tree.command"] = {
            execute = function(opts)
                captured.execute = opts
            end,
        }
        package.loaded["neo-tree.sources.manager"] = {
            get_state = function()
                return { winid = vim.api.nvim_get_current_win() }
            end,
            refresh = function(source_name)
                captured.refresh = source_name
            end,
        }

        local config = require("neo_reviewer.config")
        config.setup({
            neo_tree = {
                open_on_review = true,
                position = "right",
            },
        })

        local neotree = require("neo_reviewer.neotree")

        assert.is_true(neotree.on_review_changed())
        assert.are.same({ source = "review", position = "right" }, captured.execute)
        assert.is_nil(captured.refresh)
    end)
end)

describe("neo_reviewer.sources.review", function()
    local state
    local rendered

    before_each(function()
        package.loaded["neo_reviewer.plugin"] = nil
        package.loaded["neo_reviewer.sources.review"] = nil
        package.loaded["neo_reviewer.sources.review.components"] = nil
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo-tree.ui.renderer"] = {
            show_nodes = function(nodes, source_state)
                rendered = {
                    nodes = nodes,
                    source_state = source_state,
                }
            end,
        }

        require("neo_reviewer.plugin").register_preloads()
        state = require("neo_reviewer.state")
    end)

    after_each(function()
        package.loaded["neo-tree.sources.filesystem.components"] = nil
        package.loaded["neo_reviewer.sources.review.components"] = nil
        package.loaded["neo-tree.ui.renderer"] = nil
        state.clear_review()
        helpers.clear_all_buffers()
    end)

    it("renders changed review files as a directory tree", function()
        state.set_local_review({
            git_root = "/tmp/repo",
            files = {
                { path = "README.md", status = "modified", change_blocks = {} },
                { path = "src/foo.lua", status = "modified", change_blocks = {} },
                { path = "src/nested/bar.lua", status = "modified", change_blocks = {} },
            },
        })

        local source = require("neo_reviewer.sources.review")
        source.navigate({ path = "/tmp/repo" })

        assert.is_not_nil(rendered)
        assert.are.equal(1, #rendered.nodes)
        assert.are.equal("/tmp/repo", rendered.nodes[1].name)
        assert.is_true(rendered.nodes[1].loaded)
        assert.is_true(rendered.nodes[1]._is_expanded)

        local root_children = rendered.nodes[1].children
        assert.are.equal(2, #root_children)
        assert.are.equal("src", root_children[1].name)
        assert.are.equal("README.md", root_children[2].name)
        assert.is_true(root_children[1]._is_expanded)

        local src_children = root_children[1].children
        assert.are.equal(2, #src_children)
        assert.are.equal("nested", src_children[1].name)
        assert.are.equal("foo.lua", src_children[2].name)
        assert.is_true(src_children[1]._is_expanded)
        assert.are.equal("bar.lua", src_children[1].children[1].name)
        assert.are.equal("/tmp/repo/src/nested/bar.lua", src_children[1].children[1].path)
    end)

    it("builds filesystem-style git status lookup entries", function()
        state.set_local_review({
            git_root = "/tmp/repo",
            files = {
                { path = "README.md", status = "modified", change_blocks = {} },
                { path = "src/new.lua", status = "added", change_blocks = {} },
                { path = "src/old.lua", status = "deleted", change_blocks = {} },
            },
        })

        local source_state = {
            path = "/tmp/repo",
        }

        require("neo_reviewer.sources.review").navigate(source_state)

        assert.are.equal("M", source_state.git_status_lookup["/tmp/repo/README.md"])
        assert.are.equal("A", source_state.git_status_lookup["/tmp/repo/src/new.lua"])
        assert.are.equal("D", source_state.git_status_lookup["/tmp/repo/src/old.lua"])
        assert.are.equal("D", source_state.git_status_lookup["/tmp/repo/src"])
        assert.are.equal("D", source_state.git_status_lookup["/tmp/repo"])
    end)

    it("preloads neo-tree filesystem components for the review source", function()
        package.loaded["neo-tree.sources.filesystem.components"] = {
            name = function() end,
            current_filter = function() end,
        }

        package.loaded["neo_reviewer.sources.review.components"] = nil
        require("neo_reviewer.plugin").register_preloads()

        local components = require("neo_reviewer.sources.review.components")

        assert.are.same(package.loaded["neo-tree.sources.filesystem.components"], components)
        assert.is_function(components.name)
        assert.is_function(components.current_filter)
    end)
end)
