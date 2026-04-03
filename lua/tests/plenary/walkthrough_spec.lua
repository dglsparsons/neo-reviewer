local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path
local stub = require("luassert.stub")

describe("neo_reviewer.walkthrough", function()
    local walkthrough

    before_each(function()
        package.loaded["neo_reviewer.walkthrough"] = nil
        walkthrough = require("neo_reviewer.walkthrough")
    end)

    describe("build_prompt", function()
        it("includes the user prompt and seed context", function()
            local prompt = walkthrough.build_prompt({
                prompt = "Explain how deployments work",
                root = "/repo/root",
                seed_file = "lua/neo_reviewer/init.lua",
                seed_start_line = 10,
                seed_end_line = 20,
                seed_snippet = "function M.setup() end",
            })

            assert.is_truthy(prompt:find("Explain how deployments work"))
            assert.is_truthy(prompt:find("lua/neo_reviewer/init.lua"))
            assert.is_truthy(prompt:find("Lines: 10-20", 1, true))
            assert.is_truthy(prompt:find("function M.setup() end", 1, true))
            assert.is_truthy(prompt:find('"change_blocks"'))
            assert.is_truthy(prompt:find('"anchors"'))
        end)
    end)

    describe("parse_response", function()
        it("parses valid JSON with anchors", function()
            local output = [[
{
  "mode": "walkthrough",
  "overview": "Overview text",
  "steps": [
    {
      "title": "Step One",
      "explanation": "Explains the first step",
      "change_blocks": [],
      "anchors": [
        { "file": "src/main.lua", "start_line": 1, "end_line": 3 }
      ]
    }
  ]
}
]]

            local data, err = walkthrough.parse_response(output)
            assert.is_nil(err)
            assert.is_not_nil(data)
            assert.are.equal("walkthrough", data.mode)
            assert.are.equal("Overview text", data.overview)
            assert.are.equal(1, #data.steps)
            assert.are.equal("Step One", data.steps[1].title)
            assert.are.equal("src/main.lua", data.steps[1].anchors[1].file)
        end)

        it("errors when anchors are missing", function()
            local output = [[
{
  "overview": "Overview text",
  "steps": [
    {
      "title": "Step One",
      "explanation": "Explains the first step",
      "change_blocks": []
    }
  ]
}
]]

            local data, err = walkthrough.parse_response(output)
            assert.is_nil(data)
            assert.is_truthy(err)
        end)

        it("defaults mode when missing", function()
            local output = [[
{
  "overview": "Overview text",
  "steps": [
    {
      "title": "Step One",
      "explanation": "Explains the first step",
      "change_blocks": [],
      "anchors": []
    }
  ]
}
]]

            local data, err = walkthrough.parse_response(output)
            assert.is_nil(err)
            assert.is_not_nil(data)
            assert.are.equal("walkthrough", data.mode)
        end)
    end)

    describe("run", function()
        local Job
        local job_instance

        before_each(function()
            package.loaded["neo_reviewer.config"] = nil
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

        it("reads the final Codex message from the output file", function()
            local result
            local received_err

            walkthrough.run({
                prompt = "Explain how deployments work",
                root = "/repo/root",
            }, function(data, err)
                result = data
                received_err = err
            end)

            assert.stub(Job.new).was_called(1)
            assert.is_truthy(job_instance._opts.writer)

            local on_stdout = job_instance._opts.on_stdout
            local on_exit = job_instance._opts.on_exit
            local output_file = job_instance._opts.args[5]
            on_stdout(nil, "OpenAI Codex v0.118.0 (research preview)")
            vim.fn.writefile({
                [[{"overview":"Overview text","steps":[{"title":"Step One","explanation":"Explains the first step","change_blocks":[],"anchors":[{"file":"src/main.lua","start_line":1,"end_line":3}]}]}]],
            }, output_file)
            on_exit(nil, 0)

            vim.wait(100, function()
                return result ~= nil or received_err ~= nil
            end)

            assert.is_nil(received_err)
            assert.is_not_nil(result)
            ---@cast result NRWalkthrough
            assert.are.equal("Overview text", result.overview)
            assert.are.equal("Explain how deployments work", result.prompt)
            assert.are.equal("/repo/root", result.root)
        end)

        it("times out when the Ask AI job never exits", function()
            local config = require("neo_reviewer.config")
            config.setup({
                ai = {
                    timeout_ms = 10,
                },
            })

            local shutdown_called = 0
            job_instance.shutdown = function()
                shutdown_called = shutdown_called + 1
            end

            local result
            local received_err
            walkthrough.run({
                prompt = "Explain how deployments work",
                root = "/repo/root",
            }, function(data, err)
                result = data
                received_err = err
            end)

            vim.wait(200, function()
                return result ~= nil or received_err ~= nil
            end)

            assert.is_nil(result)
            assert.are.equal(1, shutdown_called)
            assert.is_truthy(received_err:match("timed out after 10 ms"))
        end)
    end)
end)
