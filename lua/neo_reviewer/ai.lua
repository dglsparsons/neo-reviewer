local Job = require("plenary.job")

---@class NRAIModule
local M = {}

local PROMPT_TEMPLATE = [[
You are an expert code reviewer helping a developer review a pull request efficiently.

## Your Task

Analyze this PR and return a JSON response that:
1. Summarizes the PR goal and overall risk level
2. Orders hunks in a logical sequence for review
3. Provides reviewer context for non-trivial hunks

## Step 1: Assess the PR

Read the PR title, description, and diff to understand:
- What is this PR trying to accomplish?
- How risky is the overall change? (dead code removal vs. subtle logic changes)
- What abstractions (types, traits, structs, modules) are being removed, and why?
- What new abstractions are being introduced, and why?

Provide an overall confidence score (1-5) with brief reasoning:
- 5: Very safe - pure deletions, formatting, renames, no logic changes
- 4: Low risk - straightforward changes, clear intent, unlikely to break things
- 3: Moderate - logic changes that seem correct but warrant verification
- 2: Needs scrutiny - non-obvious changes, implicit assumptions, edge case potential
- 1: High risk - complex logic, unclear purpose, touches critical paths

## Step 2: Order the Hunks

Arrange hunks so a reviewer can build understanding progressively:
1. New abstractions: New types, traits, structs, modules being introduced
2. Critical changes: Core logic changes that implement the PR's goal
3. Removed abstractions: Deleted types, traits, structs, modules
4. Tests: Unit tests, integration tests
5. Wiring: Module exports, dependency injection, plumbing code
6. Imports: Import statement changes (always trivial, always last)

Within each category, order by dependency (if A uses B, show B first).

## Step 3: Provide Reviewer Context

For each hunk, explain WHY the change was made and how it connects to other changes in this PR.

**confidence (1-5):** Same scale as PR-level confidence, applied to this specific hunk.

**category**: One of: new, critical, removed, test, wiring, imports

**context** (optional): Explain WHY this change exists and how it connects to the rest of the PR.
- ALWAYS SKIP for import changes, module exports, and simple wiring - these never need context
- SKIP for trivial changes (formatting, renames, obvious deletions)
- DO NOT describe WHAT the code does - the reviewer can read the diff
- DO explain WHY the change was made and how it relates to other changes in this PR
- DO cross-reference other hunks when relevant (e.g., "X was removed in file.rs, so Y is added here to compensate")
- NEVER tell the reviewer to verify something - do the verification yourself using the diff, then state your conclusion

Examples of BAD context (describes WHAT):
- "Removes the command argument configuration"
- "Replaced ChildManager construction with direct lambda source handling"
- "Updates the function signature to take fewer parameters"

Examples of BAD context (punts verification to reviewer):
- "Verify these fields were only used by the deleted feature"
- "Check that no other callers depend on this behavior"
- "Verify the new environment/config construction provides all necessary context"

Examples of GOOD context (explains WHY and cross-references):
- "uid/gid must be preserved for child process permissions. They were on ChildManager (removed in manager.rs), so they're passed directly here now"
- "Error handling for child_url moved here because spawn is now synchronous - url errors surface at spawn time, not later"
- "lang field removed - only used in squashball command building which is deleted in commands.rs"

## Output Format

Return ONLY valid JSON (no markdown, no explanation):
{
  "goal": "Brief statement of what this PR accomplishes",
  "confidence": 4,
  "confidence_reason": "Mostly dead code removal, but the child spawning logic changes could affect process permissions",
  "removed_abstractions": ["ChildManager - managed single/multi child processes, no longer needed with single-process model", "BootMode enum - only used for squashball startup which is removed"],
  "new_abstractions": ["prepare_child_env() - extracted from ChildManager to keep env preparation logic"],
  "hunk_order": [
    {
      "file": "path/to/spawn.rs",
      "hunk_index": 0,
      "confidence": 3,
      "category": "critical",
      "context": "uid/gid now passed directly since ChildManager is removed - preserves run-as-user behavior"
    },
    {
      "file": "path/to/manager.rs",
      "hunk_index": 0,
      "confidence": 5,
      "category": "removed"
    },
    {
      "file": "path/to/spawn.rs",
      "hunk_index": 1,
      "confidence": 5,
      "category": "imports"
    }
  ]
}

Note: `context` should be omitted for trivial/self-explanatory hunks (especially imports).

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

    if type(data.goal) ~= "string" then
        return nil, "Missing or invalid 'goal' field"
    end

    if type(data.hunk_order) ~= "table" then
        return nil, "Missing or invalid 'hunk_order' field"
    end

    -- PR-level confidence is optional but recommended
    local pr_confidence = nil
    local pr_confidence_reason = nil
    if type(data.confidence) == "number" and data.confidence >= 1 and data.confidence <= 5 then
        pr_confidence = data.confidence
        pr_confidence_reason = data.confidence_reason
    end

    ---@type NRAIHunk[]
    local hunk_order = {}
    for i, item in ipairs(data.hunk_order) do
        if type(item.file) ~= "string" then
            return nil, string.format("hunk_order[%d]: missing 'file'", i)
        end
        if type(item.hunk_index) ~= "number" then
            return nil, string.format("hunk_order[%d]: missing 'hunk_index'", i)
        end
        if type(item.confidence) ~= "number" or item.confidence < 1 or item.confidence > 5 then
            return nil, string.format("hunk_order[%d]: invalid 'confidence' (must be 1-5)", i)
        end
        if type(item.category) ~= "string" then
            return nil, string.format("hunk_order[%d]: missing 'category'", i)
        end

        table.insert(hunk_order, {
            file = item.file,
            hunk_index = item.hunk_index,
            confidence = item.confidence,
            category = item.category,
            -- Support both old "summary" and new "context" field names
            context = item.context or item.summary,
        })
    end

    -- Parse abstraction lists (optional)
    local removed_abstractions = {}
    local new_abstractions = {}
    if type(data.removed_abstractions) == "table" then
        for _, v in ipairs(data.removed_abstractions) do
            if type(v) == "string" then
                table.insert(removed_abstractions, v)
            end
        end
    end
    if type(data.new_abstractions) == "table" then
        for _, v in ipairs(data.new_abstractions) do
            if type(v) == "string" then
                table.insert(new_abstractions, v)
            end
        end
    end

    ---@type NRAIAnalysis
    local analysis = {
        goal = data.goal,
        confidence = pr_confidence,
        confidence_reason = pr_confidence_reason,
        removed_abstractions = removed_abstractions,
        new_abstractions = new_abstractions,
        hunk_order = hunk_order,
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
