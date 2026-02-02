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
      "change_blocks": [
        { "file": "path/to/file", "change_block_index": 0 }
      ]
    }
  ]
}

Guidelines:
- overview: 1-3 short paragraphs, plain language
- steps: ordered walkthrough; keep each step concise
- When a step refers to code changes, include the change blocks that support it
- change_blocks can be empty when a step is high-level or cross-cutting
- change_block_index must match the @@ change_block N @@ markers in the diff below
- Every change block in the diff must be included in at least one step
- If you are unsure, add a final step that references any remaining change blocks

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
Here are missing change blocks from a pull-requests diff. You must provide walkthrough steps that cover EVERY change block listed below. Do not reference change blocks that are not shown.

Use only the PR title/description, file list, and diff provided below. Do not invent files, APIs, or behavior that are not present.

Return ONLY valid JSON (no markdown, no explanation):
{
  "overview": "Very short summary of the missing changes (1-2 sentences).",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-3 sentences explaining why this change exists and its implications.",
      "change_blocks": [
        { "file": "path/to/file", "change_block_index": 0 }
      ]
    }
  ]
}

Guidelines:
- Every change block listed below must be included in at least one step
- steps: ordered walkthrough; keep each step concise
- change_block_index must match the @@ change_block N @@ markers in the diff below

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
---@param include_change_blocks? table<string, table<integer, boolean>>
---@return string
local function build_diff(files, include_change_blocks)
    local parts = {}
    for _, file in ipairs(files) do
        local file_blocks = {}
        for block_idx, block in ipairs(file.change_blocks or {}) do
            local change_block_index = block_idx - 1
            local include = true
            if include_change_blocks then
                include = include_change_blocks[file.path] and include_change_blocks[file.path][change_block_index]
                    or false
            end

            if include then
                local header = string.format("@@ change_block %d @@", change_block_index)
                table.insert(file_blocks, header)

                local block_lines = {}
                local added_set = {}
                local deletions_by_anchor = {}

                for _, ln in ipairs(block.added_lines or {}) do
                    added_set[ln] = true
                end
                for _, group in ipairs(block.deletion_groups or {}) do
                    deletions_by_anchor[group.anchor_line] = group.old_lines
                end

                local start_line = block.start_line or 1
                local end_line = block.end_line or start_line

                for ln = start_line, end_line do
                    local deletions = deletions_by_anchor[ln]
                    if deletions then
                        for _, old_line in ipairs(deletions) do
                            table.insert(block_lines, "-" .. old_line)
                        end
                    end
                    if added_set[ln] then
                        table.insert(block_lines, "+<added line " .. ln .. ">")
                    elseif not deletions then
                        table.insert(block_lines, " <context line " .. ln .. ">")
                    end
                end

                table.insert(file_blocks, table.concat(block_lines, "\n"))
            end
        end

        if #file_blocks > 0 then
            table.insert(parts, string.format("--- a/%s\n+++ b/%s", file.path, file.path))
            for _, part in ipairs(file_blocks) do
                table.insert(parts, part)
            end
        end
    end
    return table.concat(parts, "\n\n")
end

---@param file string
---@param change_block_index integer
---@return string
local function change_block_key(file, change_block_index)
    return file .. ":" .. tostring(change_block_index)
end

---@param review NRReview
---@return NRAIWalkthroughChangeRef[]
local function collect_all_change_blocks(review)
    ---@type NRAIWalkthroughChangeRef[]
    local blocks = {}
    for _, file in ipairs(review.files or {}) do
        for block_idx, _ in ipairs(file.change_blocks or {}) do
            table.insert(blocks, {
                file = file.path,
                change_block_index = block_idx - 1,
            })
        end
    end
    return blocks
end

---@param review NRReview
---@param analysis NRAIAnalysis
---@return table<string, boolean>
local function collect_covered_change_blocks(review, analysis)
    ---@type table<string, boolean>
    local covered = {}
    for _, step in ipairs(analysis.steps or {}) do
        for _, block_ref in ipairs(step.change_blocks or {}) do
            local file = review.files_by_path[block_ref.file]
            if file and file.change_blocks and file.change_blocks[block_ref.change_block_index + 1] then
                covered[change_block_key(block_ref.file, block_ref.change_block_index)] = true
            end
        end
    end
    return covered
end

---@param review NRReview
---@param analysis NRAIAnalysis
---@return NRAIWalkthroughChangeRef[]
local function collect_missing_change_blocks(review, analysis)
    local covered = collect_covered_change_blocks(review, analysis)
    ---@type NRAIWalkthroughChangeRef[]
    local missing = {}
    for _, block_ref in ipairs(collect_all_change_blocks(review)) do
        if not covered[change_block_key(block_ref.file, block_ref.change_block_index)] then
            table.insert(missing, block_ref)
        end
    end
    return missing
end

---@param analysis NRAIAnalysis
---@param missing NRAIWalkthroughChangeRef[]
---@return NRAIAnalysis
local function append_placeholder_steps(analysis, missing)
    analysis.steps = analysis.steps or {}
    for _, block_ref in ipairs(missing) do
        table.insert(analysis.steps, {
            title = "Uncovered change: " .. block_ref.file,
            explanation = "AI did not cover this change block; review it directly in the diff.",
            change_blocks = {
                {
                    file = block_ref.file,
                    change_block_index = block_ref.change_block_index,
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

---Build the prompt for missing change blocks analysis
---@param review NRReview
---@param missing NRAIWalkthroughChangeRef[]
---@return string
function M.build_missing_prompt(review, missing)
    local title = review.pr and review.pr.title or "Unknown"
    local description = review.pr and review.pr.description or "(No description provided)"

    ---@type table<string, boolean>
    local include_files = {}
    ---@type table<string, table<integer, boolean>>
    local include_change_blocks = {}
    for _, block_ref in ipairs(missing) do
        include_files[block_ref.file] = true
        include_change_blocks[block_ref.file] = include_change_blocks[block_ref.file] or {}
        include_change_blocks[block_ref.file][block_ref.change_block_index] = true
    end

    local file_list = build_file_list(review.files, include_files)
    local diff = build_diff(review.files, include_change_blocks)

    return string.format(MISSING_PROMPT_TEMPLATE, title, description, file_list, diff)
end

---Parse JSON response from AI CLI
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
        if type(step.change_blocks) ~= "table" then
            return nil, string.format("steps[%d]: missing 'change_blocks'", i)
        end

        ---@type NRAIWalkthroughChangeRef[]
        local change_blocks = {}
        for j, block in ipairs(step.change_blocks) do
            if type(block.file) ~= "string" then
                return nil, string.format("steps[%d].change_blocks[%d]: missing 'file'", i, j)
            end
            if type(block.change_block_index) ~= "number" then
                return nil, string.format("steps[%d].change_blocks[%d]: missing 'change_block_index'", i, j)
            end

            table.insert(change_blocks, {
                file = block.file,
                change_block_index = block.change_block_index,
            })
        end

        table.insert(steps, {
            title = step.title,
            explanation = step.explanation,
            change_blocks = change_blocks,
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
---@return NRAIAnalysis, NRAIWalkthroughChangeRef[]
function M.ensure_full_coverage(review, analysis)
    local missing = collect_missing_change_blocks(review, analysis)
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

    ---@param prompt_text string
    ---@param run_callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
    local function run_prompt(prompt_text, run_callback)
        local stdout_lines = {}
        local stderr_lines = {}
        local spec = config.build_ai_command(prompt_text)

        Job:new({
            command = spec.command,
            args = spec.args,
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
                    run_callback(nil, spec.command .. " failed: " .. stderr)
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

        local missing = collect_missing_change_blocks(review, analysis)
        if #missing == 0 then
            callback(analysis, nil)
            return
        end

        local missing_prompt = M.build_missing_prompt(review, missing)
        run_prompt(missing_prompt, function(missing_analysis)
            if missing_analysis then
                analysis = merge_analysis(analysis, missing_analysis)
            end

            local remaining = collect_missing_change_blocks(review, analysis)
            if #remaining > 0 then
                analysis = append_placeholder_steps(analysis, remaining)
            end

            callback(analysis, nil)
        end)
    end)
end

return M
