local Job = require("plenary.job")

---@class NRAIModule
local M = {}

local PROMPT_TEMPLATE = [[
Here is the contents of a pull-requests diff. I want you to break this down and explain it to a human in the simplest, most concise (but still comprehensive) way possible. Your goal is to walk them through the changes so they are able to comment on the PR, and understand its implications. They may not have existing knowledge of this codebase.

Read all relevant files and code to help yourself understand the changes before attempting to walk them through this.

Use only the PR title/description, file list, and diff provided below. Do not invent files, APIs, or behavior that are not present.

Return ONLY valid JSON (no markdown, no explanation):
{
  "overview": "Concise explanation of the PR in plain language. 1-3 short paragraphs.",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-4 sentences explaining why this change exists and its implications.",
      "hunks": [
        { "file": "path/to/file", "hunk_index": 0 }
      ]
    }
  ]
}

Guidelines:
- overview: 1-3 short paragraphs, plain language
- steps: ordered walkthrough; keep each step concise
- When a step refers to code changes, include the hunks that support it
- hunks can be empty when a step is high-level or cross-cutting
- hunk_index must match the @@ hunk N @@ markers in the diff below

---

PR Title: %s

PR Description:
%s

Files Changed:
%s

Unified Diff:
%s
]]

---Build file list with status for the prompt
---@param files NRFile[]
---@return string
local function build_file_list(files)
    local lines = {}
    for _, file in ipairs(files) do
        local icon = ({ added = "+", deleted = "-", modified = "~", renamed = "R" })[file.status] or "?"
        table.insert(
            lines,
            string.format("[%s] %s (+%d/-%d)", icon, file.path, file.additions or 0, file.deletions or 0)
        )
    end
    return table.concat(lines, "\n")
end

---Build unified diff from files for the prompt
---@param files NRFile[]
---@return string
local function build_diff(files)
    local parts = {}
    for _, file in ipairs(files) do
        if #file.hunks > 0 then
            table.insert(parts, string.format("--- a/%s\n+++ b/%s", file.path, file.path))
            for hunk_idx, hunk in ipairs(file.hunks) do
                local header = string.format("@@ hunk %d @@", hunk_idx - 1)
                table.insert(parts, header)

                local hunk_lines = {}
                local added_set = {}
                local deleted_set = {}

                for _, ln in ipairs(hunk.added_lines or {}) do
                    added_set[ln] = true
                end
                for i, pos in ipairs(hunk.deleted_at or {}) do
                    deleted_set[pos] = hunk.old_lines[i]
                end

                local start_line = hunk.start or 1
                local end_line = start_line + (hunk.count or 1) - 1

                for ln = start_line, end_line do
                    if deleted_set[ln] then
                        table.insert(hunk_lines, "-" .. deleted_set[ln])
                    end
                    if added_set[ln] then
                        table.insert(hunk_lines, "+<added line " .. ln .. ">")
                    elseif not deleted_set[ln] then
                        table.insert(hunk_lines, " <context line " .. ln .. ">")
                    end
                end

                table.insert(parts, table.concat(hunk_lines, "\n"))
            end
        end
    end
    return table.concat(parts, "\n\n")
end

---Build the prompt for AI analysis
---@param review NRReview
---@return string
function M.build_prompt(review)
    local title = review.pr and review.pr.title or "Unknown"
    local description = review.pr and review.pr.description or "(No description provided)"
    local file_list = build_file_list(review.files)
    local diff = build_diff(review.files)

    return string.format(PROMPT_TEMPLATE, title, description, file_list, diff)
end

---Parse JSON response from opencode
---@param output string
---@return NRAIAnalysis|nil, string|nil
local function parse_response(output)
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

    if type(data.overview) ~= "string" then
        return nil, "Missing or invalid 'overview' field"
    end

    if type(data.steps) ~= "table" then
        return nil, "Missing or invalid 'steps' field"
    end

    ---@type NRAIWalkthroughStep[]
    local steps = {}
    for i, step in ipairs(data.steps) do
        if type(step.title) ~= "string" then
            return nil, string.format("steps[%d]: missing 'title'", i)
        end
        if type(step.explanation) ~= "string" then
            return nil, string.format("steps[%d]: missing 'explanation'", i)
        end
        if type(step.hunks) ~= "table" then
            return nil, string.format("steps[%d]: missing 'hunks'", i)
        end

        ---@type NRAIWalkthroughHunkRef[]
        local hunks = {}
        for j, hunk in ipairs(step.hunks) do
            if type(hunk.file) ~= "string" then
                return nil, string.format("steps[%d].hunks[%d]: missing 'file'", i, j)
            end
            if type(hunk.hunk_index) ~= "number" then
                return nil, string.format("steps[%d].hunks[%d]: missing 'hunk_index'", i, j)
            end

            table.insert(hunks, {
                file = hunk.file,
                hunk_index = hunk.hunk_index,
            })
        end

        table.insert(steps, {
            title = step.title,
            explanation = step.explanation,
            hunks = hunks,
        })
    end

    ---@type NRAIAnalysis
    local analysis = {
        overview = data.overview,
        steps = steps,
    }

    return analysis, nil
end

---Run AI analysis on a PR review
---@param review NRReview
---@param callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
function M.analyze_pr(review, callback)
    local config = require("neo_reviewer.config")
    local prompt = M.build_prompt(review)

    local cmd = config.values.ai.command
    local model = config.values.ai.model

    local stdout_lines = {}
    local stderr_lines = {}

    Job:new({
        command = cmd,
        args = { "run", "--model", model },
        writer = prompt,
        on_stdout = function(_, line)
            table.insert(stdout_lines, line)
        end,
        on_stderr = function(_, line)
            table.insert(stderr_lines, line)
        end,
        on_exit = vim.schedule_wrap(function(_, code)
            if code ~= 0 then
                local stderr = table.concat(stderr_lines, "\n")
                callback(nil, "opencode failed: " .. stderr)
                return
            end

            local output = table.concat(stdout_lines, "\n")
            local analysis, err = parse_response(output)
            callback(analysis, err)
        end),
    }):start()
end

return M
