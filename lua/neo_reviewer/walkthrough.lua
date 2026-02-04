local Job = require("plenary.job")

---@class NRWalkthroughContext
---@field prompt string
---@field root string
---@field seed_file? string
---@field seed_start_line? integer
---@field seed_end_line? integer
---@field seed_snippet? string

---@class NRWalkthroughModule
local M = {}

local PROMPT_TEMPLATE = [[
You are an AI assistant running inside a git repository at: %s

User request:
%s

Rules:
- Read files directly from disk using repo-relative paths.
- Only use git-tracked files (ignore untracked/build/vendor).
- You may use git and ripgrep to locate relevant code.
- Do not invent files, APIs, or behavior not present in the repo.
- Provide a concise overview and an ordered walkthrough.
- Use plain, everyday language and short sentences.
- Avoid jargon and acronyms; if you must use one, define it in the same sentence.
- Use 1-based, inclusive line numbers for anchors.

Seed context (may be empty):
%s

Return ONLY valid JSON (no markdown, no extra text):
{
  "mode": "walkthrough" | "conceptual",
  "overview": "1-3 short paragraphs",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-4 sentences",
      "anchors": [
        { "file": "path/to/file", "start_line": 1, "end_line": 10 }
      ]
    }
  ]
}

Guidelines:
- Decide whether the user request is best answered as a code walkthrough or a conceptual explanation.
- Use "walkthrough" when pointing to specific code will help; use "conceptual" for high-level or architecture questions.
- Always include at least one step. Steps should be ordered for a human walkthrough.
- If mode is "walkthrough", every step must include at least one anchor.
- Anchors should be tight (aim for 3-20 lines) and must use repo-relative paths.
- If mode is "conceptual", anchors can be empty, but keep the field present.
- If you mention a specific file or function, include an anchor even in conceptual mode.
- Do not include follow-up questions; focus on the explanation.
]]

---@param ctx NRWalkthroughContext
---@return string
function M.build_prompt(ctx)
    local seed_lines = {}
    if ctx.seed_file then
        table.insert(seed_lines, string.format("File: %s", ctx.seed_file))
    end
    if ctx.seed_start_line and ctx.seed_end_line then
        table.insert(seed_lines, string.format("Lines: %d-%d", ctx.seed_start_line, ctx.seed_end_line))
    end
    if ctx.seed_snippet and ctx.seed_snippet ~= "" then
        table.insert(seed_lines, "Snippet:")
        table.insert(seed_lines, ctx.seed_snippet)
    end

    local seed_text = #seed_lines > 0 and table.concat(seed_lines, "\n") or "None."
    return string.format(PROMPT_TEMPLATE, ctx.root, ctx.prompt, seed_text)
end

---@param output string
---@return NRWalkthrough|nil, string|nil
function M.parse_response(output)
    local json_start = output:find("{")
    local json_end = output:reverse():find("}")
    if not json_start or not json_end then
        return nil, "No JSON object found in response"
    end

    json_end = #output - json_end + 1
    local json_str = output:sub(json_start, json_end)

    local ok, data = pcall(vim.json.decode, json_str)
    if not ok then
        return nil, "Failed to parse JSON: " .. tostring(data)
    end

    local mode = data.mode
    if mode == nil then
        mode = "walkthrough"
    end
    if mode ~= "walkthrough" and mode ~= "conceptual" then
        return nil, "Missing or invalid 'mode' field"
    end

    if type(data.overview) ~= "string" then
        return nil, "Missing or invalid 'overview' field"
    end

    if type(data.steps) ~= "table" then
        return nil, "Missing or invalid 'steps' field"
    end

    ---@type NRWalkthroughStep[]
    local steps = {}
    for i, step in ipairs(data.steps) do
        if type(step.title) ~= "string" then
            return nil, string.format("steps[%d]: missing 'title'", i)
        end
        if type(step.explanation) ~= "string" then
            return nil, string.format("steps[%d]: missing 'explanation'", i)
        end
        if type(step.anchors) ~= "table" then
            return nil, string.format("steps[%d]: missing 'anchors'", i)
        end

        ---@type NRWalkthroughAnchor[]
        local anchors = {}
        for j, anchor in ipairs(step.anchors) do
            if type(anchor.file) ~= "string" then
                return nil, string.format("steps[%d].anchors[%d]: missing 'file'", i, j)
            end
            if type(anchor.start_line) ~= "number" then
                return nil, string.format("steps[%d].anchors[%d]: missing 'start_line'", i, j)
            end
            if type(anchor.end_line) ~= "number" then
                return nil, string.format("steps[%d].anchors[%d]: missing 'end_line'", i, j)
            end

            table.insert(anchors, {
                file = anchor.file,
                start_line = anchor.start_line,
                end_line = anchor.end_line,
            })
        end

        table.insert(steps, {
            title = step.title,
            explanation = step.explanation,
            anchors = anchors,
        })
    end

    ---@type NRWalkthrough
    local walkthrough = {
        mode = mode,
        overview = data.overview,
        steps = steps,
        prompt = "",
        root = "",
    }

    return walkthrough, nil
end

---@param ctx NRWalkthroughContext
---@param callback fun(result: NRWalkthrough|nil, err: string|nil)
---@return nil
function M.run(ctx, callback)
    if not ctx.root or ctx.root == "" then
        ctx.root = vim.fn.getcwd()
    end

    local config = require("neo_reviewer.config")
    local prompt = M.build_prompt(ctx)
    local stdout_lines = {}
    local stderr_lines = {}
    local spec = config.build_ai_command(prompt)

    Job:new({
        command = spec.command,
        args = spec.args,
        cwd = ctx.root,
        writer = spec.writer,
        on_stdout = function(_, line)
            table.insert(stdout_lines, line)
        end,
        on_stderr = function(_, line)
            table.insert(stderr_lines, line)
        end,
        on_exit = vim.schedule_wrap(function(_, code)
            if code ~= 0 then
                local stderr = table.concat(stderr_lines, "\n")
                callback(nil, spec.command .. " failed: " .. stderr)
                return
            end

            local output = table.concat(stdout_lines, "\n")
            local walkthrough, err = M.parse_response(output)
            if not walkthrough then
                callback(nil, err)
                return
            end

            walkthrough.prompt = ctx.prompt
            walkthrough.root = ctx.root

            callback(walkthrough, nil)
        end),
    }):start()
end

return M
