describe("greviewer.config", function()
    local config

    before_each(function()
        package.loaded["greviewer.config"] = nil
        config = require("greviewer.config")
    end)

    describe("default values", function()
        it("has default cli_path", function()
            assert.are.equal("greviewer-cli", config.values.cli_path)
        end)

        it("has default signs", function()
            assert.are.equal("+", config.values.signs.add)
            assert.are.equal("-", config.values.signs.delete)
            assert.are.equal("~", config.values.signs.change)
        end)

        it("has wrap_navigation enabled by default", function()
            assert.is_true(config.values.wrap_navigation)
        end)

        it("has auto_expand_deletes disabled by default", function()
            assert.is_false(config.values.auto_expand_deletes)
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

        it("overrides wrap_navigation", function()
            config.setup({ wrap_navigation = false })
            assert.is_false(config.values.wrap_navigation)
        end)

        it("overrides auto_expand_deletes", function()
            config.setup({ auto_expand_deletes = true })
            assert.is_true(config.values.auto_expand_deletes)
        end)

        it("handles nil opts", function()
            assert.has_no_errors(function()
                config.setup(nil)
            end)
            assert.are.equal("greviewer-cli", config.values.cli_path)
        end)

        it("handles empty opts", function()
            assert.has_no_errors(function()
                config.setup({})
            end)
            assert.are.equal("greviewer-cli", config.values.cli_path)
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
            config.setup({ wrap_navigation = false })

            assert.are.equal("custom", config.values.cli_path)
            assert.is_false(config.values.wrap_navigation)
        end)
    end)
end)
