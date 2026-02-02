local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

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
      "explanation": "Explains the first step"
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
end)
