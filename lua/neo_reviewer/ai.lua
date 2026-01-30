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
- Every hunk in the diff must be included in at least one step
- If you are unsure, add a final step that references any remaining hunks

---

PR Title: %s

PR Description:
%s

Files Changed:
%s

Unified Diff:
%s
]]

local MISSING_PROMPT_TEMPLATE = [[
Here are missing hunks from a pull-requests diff. You must provide walkthrough steps that cover EVERY hunk listed below. Do not reference hunks that are not shown.

Use only the PR title/description, file list, and diff provided below. Do not invent files, APIs, or behavior that are not present.

Return ONLY valid JSON (no markdown, no explanation):
{
  "overview": "Very short summary of the missing changes (1-2 sentences).",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-3 sentences explaining why this change exists and its implications.",
      "hunks": [
        { "file": "path/to/file", "hunk_index": 0 }
      ]
    }
  ]
}

Guidelines:
- Every hunk listed below must be included in at least one step
- steps: ordered walkthrough; keep each step concise
- hunk_index must match the @@ hunk N @@ markers in the diff below

---

PR Title: %s

PR Description:
%s

Files Changed (missing only):
%s

Unified Diff (missing only):
%s
]]

---Build file list with status for the prompt
---@param files NRFile[]
---@param include_files? table<string, boolean>
---@return string
local function build_file_list(files, include_files)
    local lines = {}
    for _, file in ipairs(files) do
        if not include_files or include_files[file.path] then
            local icon = ({ added = "+", deleted = "-", modified = "~", renamed = "R" })[file.status] or "?"
            table.insert(
                lines,
                string.format("[%s] %s (+%d/-%d)", icon, file.path, file.additions or 0, file.deletions or 0)
            )
        end
    end
    return table.concat(lines, "\n")
end

---Build unified diff from files for the prompt
---@param files NRFile[]
---@param include_hunks? table<string, table<integer, boolean>>
---@return string
local function build_diff(files, include_hunks)
    local parts = {}
    for _, file in ipairs(files) do
        local file_hunks = {}
        for hunk_idx, hunk in ipairs(file.hunks or {}) do
            local hunk_index = hunk_idx - 1
            local include = true
            if include_hunks then
                include = include_hunks[file.path] and include_hunks[file.path][hunk_index] or false
            end

            if include then
                local header = string.format("@@ hunk %d @@", hunk_index)
                table.insert(file_hunks, header)

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

                table.insert(file_hunks, table.concat(hunk_lines, "\n"))
            end
        end

        if #file_hunks > 0 then
            table.insert(parts, string.format("--- a/%s\n+++ b/%s", file.path, file.path))
            for _, part in ipairs(file_hunks) do
                table.insert(parts, part)
            end
        end
    end
    return table.concat(parts, "\n\n")
end

---@param file string
---@param hunk_index integer
---@return string
local function hunk_key(file, hunk_index)
    return file .. ":" .. tostring(hunk_index)
end

---@param review NRReview
---@return NRAIWalkthroughHunkRef[]
local function collect_all_hunks(review)
    ---@type NRAIWalkthroughHunkRef[]
    local hunks = {}
    for _, file in ipairs(review.files or {}) do
        for hunk_idx, _ in ipairs(file.hunks or {}) do
            table.insert(hunks, {
                file = file.path,
                hunk_index = hunk_idx - 1,
            })
        end
    end
    return hunks
end

---@param review NRReview
---@param analysis NRAIAnalysis
---@return table<string, boolean>
local function collect_covered_hunks(review, analysis)
    ---@type table<string, boolean>
    local covered = {}
    for _, step in ipairs(analysis.steps or {}) do
        for _, hunk_ref in ipairs(step.hunks or {}) do
            local file = review.files_by_path[hunk_ref.file]
            if file and file.hunks and file.hunks[hunk_ref.hunk_index + 1] then
                covered[hunk_key(hunk_ref.file, hunk_ref.hunk_index)] = true
            end
        end
    end
    return covered
end

---@param review NRReview
---@param analysis NRAIAnalysis
---@return NRAIWalkthroughHunkRef[]
local function collect_missing_hunks(review, analysis)
    local covered = collect_covered_hunks(review, analysis)
    ---@type NRAIWalkthroughHunkRef[]
    local missing = {}
    for _, hunk_ref in ipairs(collect_all_hunks(review)) do
        if not covered[hunk_key(hunk_ref.file, hunk_ref.hunk_index)] then
            table.insert(missing, hunk_ref)
        end
    end
    return missing
end

---@param analysis NRAIAnalysis
---@param missing NRAIWalkthroughHunkRef[]
---@return NRAIAnalysis
local function append_placeholder_steps(analysis, missing)
    analysis.steps = analysis.steps or {}
    for _, hunk_ref in ipairs(missing) do
        table.insert(analysis.steps, {
            title = "Uncovered change: " .. hunk_ref.file,
            explanation = "AI did not cover this hunk; review it directly in the diff.",
            hunks = {
                {
                    file = hunk_ref.file,
                    hunk_index = hunk_ref.hunk_index,
                },
            },
        })
    end
    return analysis
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

---Build the prompt for missing hunks analysis
---@param review NRReview
---@param missing NRAIWalkthroughHunkRef[]
---@return string
function M.build_missing_prompt(review, missing)
    local title = review.pr and review.pr.title or "Unknown"
    local description = review.pr and review.pr.description or "(No description provided)"

    ---@type table<string, boolean>
    local include_files = {}
    ---@type table<string, table<integer, boolean>>
    local include_hunks = {}
    for _, hunk_ref in ipairs(missing) do
        include_files[hunk_ref.file] = true
        include_hunks[hunk_ref.file] = include_hunks[hunk_ref.file] or {}
        include_hunks[hunk_ref.file][hunk_ref.hunk_index] = true
    end

    local file_list = build_file_list(review.files, include_files)
    local diff = build_diff(review.files, include_hunks)

    return string.format(MISSING_PROMPT_TEMPLATE, title, description, file_list, diff)
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

---@param review NRReview
---@param analysis NRAIAnalysis
---@return NRAIAnalysis, NRAIWalkthroughHunkRef[]
function M.ensure_full_coverage(review, analysis)
    local missing = collect_missing_hunks(review, analysis)
    if #missing == 0 then
        return analysis, missing
    end
    return append_placeholder_steps(analysis, missing), missing
end

---@param base NRAIAnalysis
---@param extra NRAIAnalysis
---@return NRAIAnalysis
local function merge_analysis(base, extra)
    base.steps = base.steps or {}
    for _, step in ipairs(extra.steps or {}) do
        table.insert(base.steps, step)
    end
    return base
end

---Run AI analysis on a PR review
---@param review NRReview
---@param callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
function M.analyze_pr(review, callback)
    local config = require("neo_reviewer.config")
    local prompt = M.build_prompt(review)

    local cmd = config.values.ai.command
    local model = config.values.ai.model

    ---@param prompt_text string
    ---@param run_callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
    local function run_prompt(prompt_text, run_callback)
        local stdout_lines = {}
        local stderr_lines = {}

        Job:new({
            command = cmd,
            args = { "run", "--model", model },
            writer = prompt_text,
            on_stdout = function(_, line)
                table.insert(stdout_lines, line)
            end,
            on_stderr = function(_, line)
                table.insert(stderr_lines, line)
            end,
            on_exit = vim.schedule_wrap(function(_, code)
                if code ~= 0 then
                    local stderr = table.concat(stderr_lines, "\n")
                    run_callback(nil, "opencode failed: " .. stderr)
                    return
                end

                local output = table.concat(stdout_lines, "\n")
                local analysis, err = parse_response(output)
                run_callback(analysis, err)
            end),
        }):start()
    end

    run_prompt(prompt, function(analysis, err)
        if not analysis or err then
            callback(nil, err)
            return
        end

        local missing = collect_missing_hunks(review, analysis)
        if #missing == 0 then
            callback(analysis, nil)
            return
        end

        local missing_prompt = M.build_missing_prompt(review, missing)
        run_prompt(missing_prompt, function(missing_analysis, _missing_err)
            if missing_analysis then
                analysis = merge_analysis(analysis, missing_analysis)
            end

            local remaining = collect_missing_hunks(review, analysis)
            if #remaining > 0 then
                analysis = append_placeholder_steps(analysis, remaining)
            end

            callback(analysis, nil)
        end)
    end)
end

return M
