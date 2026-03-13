describe("neo_reviewer.config", function()
    local config

    before_each(function()
        package.loaded["neo_reviewer.config"] = nil
        config = require("neo_reviewer.config")
    end)

    describe("default values", function()
        it("has default cli_path", function()
            assert.are.equal("neo-reviewer", config.values.cli_path)
        end)

        it("has default signs", function()
            assert.are.equal("+", config.values.signs.add)
            assert.are.equal("-", config.values.signs.delete)
            assert.are.equal("~", config.values.signs.change)
        end)

        it("has auto_expand_deletes disabled by default", function()
            assert.is_false(config.values.auto_expand_deletes)
        end)

        it("has default thread window keys for reply/edit/delete", function()
            assert.are.equal("r", config.values.thread_window.keys.reply)
            assert.are.equal("e", config.values.thread_window.keys.edit)
            assert.are.equal("d", config.values.thread_window.keys.delete)
        end)

        it("skips noise files in review_diff by default", function()
            assert.is_true(config.values.review_diff.skip_noise_files)
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, "pnpm-lock.yaml"))
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, "Cargo.lock"))
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, "poetry.lock"))
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, "Package.resolved"))
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, "packages.lock.json"))
            assert.is_true(vim.tbl_contains(config.values.review_diff.noise_files, ".terraform.lock.hcl"))
        end)

        it("has sync automation enabled by default", function()
            assert.is_true(config.values.sync.on_save)
            assert.are.equal(400, config.values.sync.save_debounce_ms)
            assert.is_true(config.values.sync.periodic_enabled)
            assert.are.equal(120000, config.values.sync.periodic_interval_ms)
            assert.are.equal(1500, config.values.sync.cooldown_ms)
        end)

        it("has walkthrough step list and Neo-tree defaults", function()
            assert.are.equal(52, config.values.ai.walkthrough_window.step_list_width)
            assert.is_false(config.values.neo_tree.open_on_review)
            assert.are.equal("left", config.values.neo_tree.position)
        end)
    end)

    describe("setup", function()
        it("overrides cli_path", function()
            config.setup({ cli_path = "/custom/path/cli" })
            assert.are.equal("/custom/path/cli", config.values.cli_path)
        end)

        it("overrides individual signs", function()
            config.setup({
                signs = {
                    add = "A",
                },
            })

            assert.are.equal("A", config.values.signs.add)
            assert.are.equal("-", config.values.signs.delete)
            assert.are.equal("~", config.values.signs.change)
        end)

        it("overrides all signs", function()
            config.setup({
                signs = {
                    add = "++",
                    delete = "--",
                    change = "~~",
                },
            })

            assert.are.equal("++", config.values.signs.add)
            assert.are.equal("--", config.values.signs.delete)
            assert.are.equal("~~", config.values.signs.change)
        end)

        it("overrides auto_expand_deletes", function()
            config.setup({ auto_expand_deletes = true })
            assert.is_true(config.values.auto_expand_deletes)
        end)

        it("overrides review_diff noise settings", function()
            config.setup({
                review_diff = {
                    skip_noise_files = false,
                    noise_files = { "custom.lock" },
                },
            })

            assert.is_false(config.values.review_diff.skip_noise_files)
            assert.are.same({ "custom.lock" }, config.values.review_diff.noise_files)
        end)

        it("overrides sync automation settings", function()
            config.setup({
                sync = {
                    on_save = false,
                    save_debounce_ms = 900,
                    periodic_enabled = false,
                    periodic_interval_ms = 60000,
                    cooldown_ms = 250,
                },
            })

            assert.is_false(config.values.sync.on_save)
            assert.are.equal(900, config.values.sync.save_debounce_ms)
            assert.is_false(config.values.sync.periodic_enabled)
            assert.are.equal(60000, config.values.sync.periodic_interval_ms)
            assert.are.equal(250, config.values.sync.cooldown_ms)
        end)

        it("overrides walkthrough step list width and Neo-tree options", function()
            config.setup({
                ai = {
                    walkthrough_window = {
                        step_list_width = 36,
                    },
                },
                neo_tree = {
                    open_on_review = true,
                    position = "right",
                },
            })

            assert.are.equal(36, config.values.ai.walkthrough_window.step_list_width)
            assert.is_true(config.values.neo_tree.open_on_review)
            assert.are.equal("right", config.values.neo_tree.position)
        end)

        it("overrides thread window edit and delete keys", function()
            config.setup({
                thread_window = {
                    keys = {
                        edit = "E",
                        delete = "D",
                    },
                },
            })

            assert.are.equal("E", config.values.thread_window.keys.edit)
            assert.are.equal("D", config.values.thread_window.keys.delete)
            assert.are.equal("r", config.values.thread_window.keys.reply)
        end)

        it("handles nil opts", function()
            assert.has_no_errors(function()
                config.setup(nil)
            end)
            assert.are.equal("neo-reviewer", config.values.cli_path)
        end)

        it("handles empty opts", function()
            assert.has_no_errors(function()
                config.setup({})
            end)
            assert.are.equal("neo-reviewer", config.values.cli_path)
        end)

        it("ignores unknown options", function()
            assert.has_no_errors(function()
                config.setup({
                    unknown_option = "value",
                    another_unknown = 123,
                })
            end)
        end)

        it("can be called multiple times", function()
            config.setup({ cli_path = "first" })
            assert.are.equal("first", config.values.cli_path)

            config.setup({ cli_path = "second" })
            assert.are.equal("second", config.values.cli_path)
        end)

        it("accumulates changes across multiple calls", function()
            config.setup({ cli_path = "custom" })
            config.setup({ auto_expand_deletes = true })

            assert.are.equal("custom", config.values.cli_path)
            assert.is_true(config.values.auto_expand_deletes)
        end)
    end)
end)
