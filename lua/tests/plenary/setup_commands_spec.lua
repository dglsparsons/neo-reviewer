local stub = require("luassert.stub")
local helpers = require("plenary.helpers")

describe("neo_reviewer setup commands", function()
    local command_stub
    local created
    local created_commands
    local original_executable
    local notifications

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.config"] = nil

        created = {}
        created_commands = {}
        command_stub = stub(vim.api, "nvim_create_user_command")
        command_stub.invokes(function(name, callback)
            table.insert(created, name)
            created_commands[name] = callback
        end)

        original_executable = vim.fn.executable
        vim.fn.executable = function()
            return 1
        end

        notifications = helpers.capture_notifications()
    end)

    after_each(function()
        command_stub:revert()
        vim.fn.executable = original_executable
        notifications.restore()
    end)

    it("registers Ask and drops Explore", function()
        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.setup()

        local has_ask = false
        local has_explore = false
        for _, name in ipairs(created) do
            if name == "Ask" then
                has_ask = true
            elseif name == "Explore" then
                has_explore = true
            end
        end

        assert.is_true(has_ask)
        assert.is_false(has_explore)
        assert.is_function(neo_reviewer.ask)
        assert.is_nil(rawget(neo_reviewer, "explore"))
    end)

    it("parses ReviewDiff target and selector flags", function()
        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.setup()

        local captured_opts
        local original_review_diff = neo_reviewer.review_diff
        neo_reviewer.review_diff = function(opts)
            captured_opts = opts
        end

        created_commands.ReviewDiff({ args = "main --merge-base --tracked-only --no-analyze" })

        neo_reviewer.review_diff = original_review_diff

        assert.are.same({
            analyze = false,
            target = "main",
            merge_base = true,
            tracked_only = true,
        }, captured_opts)
    end)

    it("rejects invalid ReviewDiff flag combinations from command args", function()
        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.setup()

        created_commands.ReviewDiff({ args = "--cached-only --uncached-only" })

        local found = false
        for _, n in ipairs(notifications.get()) do
            if n.msg:match("Cannot combine %-%-cached%-only and %-%-uncached%-only for :ReviewDiff") then
                found = true
                break
            end
        end
        assert.is_true(found, "Expected ReviewDiff parse error notification")
    end)

    it("rejects unknown ReviewDiff flags", function()
        local neo_reviewer = require("neo_reviewer")
        neo_reviewer.setup()

        created_commands.ReviewDiff({ args = "--cached" })

        local found = false
        for _, n in ipairs(notifications.get()) do
            if n.msg:match("Unknown flag for :ReviewDiff: %-%-cached") then
                found = true
                break
            end
        end
        assert.is_true(found, "Expected unknown flag parse error notification")
    end)
end)
