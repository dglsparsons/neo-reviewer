local stub = require("luassert.stub")

describe("neo_reviewer setup commands", function()
    local command_stub
    local created
    local original_executable

    before_each(function()
        package.loaded["neo_reviewer"] = nil
        package.loaded["neo_reviewer.config"] = nil

        created = {}
        command_stub = stub(vim.api, "nvim_create_user_command")
        command_stub.invokes(function(name)
            table.insert(created, name)
        end)

        original_executable = vim.fn.executable
        vim.fn.executable = function()
            return 1
        end
    end)

    after_each(function()
        command_stub:revert()
        vim.fn.executable = original_executable
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
        assert.is_nil(neo_reviewer.explore)
    end)
end)
