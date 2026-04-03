local Job = require("plenary.job")
local uv = vim.uv or vim.loop

---@class NRAIModule
local M = {}

---@class NRProcessHandle: uv.uv_handle_t
---@field kill fun(self: NRProcessHandle, signal: string)

---@class NRAIJob
---@field handle? NRProcessHandle
---@field pid? integer
---@field is_shutdown? boolean
---@field shutdown? fun(self: NRAIJob, code?: integer, signal?: integer)
---@field start fun(self: NRAIJob)

local PROMPT_TEMPLATE = [[
You are an AI assistant running inside a git repo at: %s

Explain this change to a reviewer who is new to the codebase. Explain it like a human would, using high-level, simple to grok concepts or abstractions. Be brief, concrete and use plain-language.

Rules:
- Read repo-relative files from disk for context.
- Only use git-tracked files; ignore untracked/build/vendor.
- Use the PR title, description, file list, and diff below.
- Added and context lines in the diff are placeholders; inspect files to understand the new code.
- Treat formatting-only edits as non-functional.
- Cover every change block exactly once.

Return ONLY valid JSON (no markdown, no explanation):
{
  "overview": "Short explanation of the PR in plain language. 1-2 short paragraphs.",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-3 short sentences describing the change and what the reviewer should notice.",
      "change_blocks": [
        { "file": "path/to/file", "change_block_index": 0 }
      ],
      "anchors": [
        { "file": "path/to/file", "start_line": 1, "end_line": 10 }
      ]
    }
  ]
}

Guidelines:
- overview: 1 sentence
- steps: ordered to explain the change to a human as logically as possible
- Use a small number of meaningful steps and group related edits
- Each explanation should be 1 short sentence with enough context to explain why the change exists
- Each step must include one or more change blocks
- Include anchors when they help; otherwise use an empty array
- Titles should still make sense on their own
- Keep anchors tight (about 3-20 lines) and repo-relative
- change_block_index must match the @@ change_block N @@ markers below
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

---@param review NRReview
---@param block_ref NRAIWalkthroughChangeRef
---@return boolean
local function is_valid_change_block_ref(review, block_ref)
    local file = review.files_by_path[block_ref.file]
    if not file then
        return false
    end
    return file.change_blocks and file.change_blocks[block_ref.change_block_index + 1] ~= nil
end

---Normalize AI steps so each unique change block maps to at most one step.
---Invalid and duplicate block references are removed, while grouped steps are preserved.
---@param review NRReview
---@param analysis NRAIAnalysis
---@return NRAIAnalysis
local function normalize_steps_to_unique_change_blocks(review, analysis)
    ---@type NRAIAnalysis
    local normalized = {
        overview = analysis.overview,
        steps = {},
    }

    ---@type table<string, boolean>
    local seen = {}
    for _, step in ipairs(analysis.steps or {}) do
        ---@type NRAIWalkthroughChangeRef[]
        local change_blocks = {}
        for _, block_ref in ipairs(step.change_blocks or {}) do
            if is_valid_change_block_ref(review, block_ref) then
                local key = change_block_key(block_ref.file, block_ref.change_block_index)
                if not seen[key] then
                    table.insert(change_blocks, {
                        file = block_ref.file,
                        change_block_index = block_ref.change_block_index,
                    })
                    seen[key] = true
                end
            end
        end

        if #change_blocks > 0 then
            table.insert(normalized.steps, {
                title = step.title,
                explanation = step.explanation,
                change_blocks = change_blocks,
                anchors = step.anchors or {},
            })
        end
    end

    return normalized
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
            anchors = {},
        })
    end
    return analysis
end

---@param review NRReview
---@return string?
local function resolve_root(review)
    if review.git_root and review.git_root ~= "" then
        return review.git_root
    end
    if vim and vim.fn and vim.fn.getcwd then
        local cwd = vim.fn.getcwd()
        if cwd and cwd ~= "" then
            return cwd
        end
    end
    return nil
end

---Build the prompt for AI analysis
---@param review NRReview
---@return string
function M.build_prompt(review)
    local title = review.pr and review.pr.title or "Unknown"
    local description = review.pr and review.pr.description or "(No description provided)"
    local file_list = build_file_list(review.files)
    local diff = build_diff(review.files)
    local root = resolve_root(review) or "Unknown"

    return string.format(PROMPT_TEMPLATE, root, title, description, file_list, diff)
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
        if type(step.anchors) ~= "table" then
            return nil, string.format("steps[%d]: missing 'anchors'", i)
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
            change_blocks = change_blocks,
            anchors = anchors,
        })
    end

    ---@type NRAIAnalysis
    local analysis = {
        overview = data.overview,
        steps = steps,
    }

    return analysis, nil
end

---@param spec NRAICommandSpec
---@param stdout_lines string[]
---@return string|nil, string|nil
local function collect_command_output(spec, stdout_lines)
    if not spec.output_file then
        return table.concat(stdout_lines, "\n"), nil
    end

    local output_file = spec.output_file
    if not output_file or output_file == "" then
        return nil, string.format("%s did not declare an AI output file", spec.command)
    end

    if vim.fn.filereadable(output_file) ~= 1 then
        return nil, string.format("%s did not write final output to %s", spec.command, output_file)
    end

    local lines = vim.fn.readfile(output_file)
    local delete_ok = vim.fn.delete(output_file)
    if delete_ok ~= 0 then
        vim.schedule(function()
            vim.notify(
                string.format("[neo-reviewer] Failed to delete AI output file: %s", output_file),
                vim.log.levels.WARN
            )
        end)
    end

    return table.concat(lines, "\n"), nil
end

---@param spec NRAICommandSpec
---@return nil
local function cleanup_output_file(spec)
    local output_file = spec.output_file
    if not output_file or output_file == "" then
        return
    end

    if vim.fn.filereadable(output_file) ~= 1 then
        return
    end

    local delete_ok = vim.fn.delete(output_file)
    if delete_ok ~= 0 then
        vim.schedule(function()
            vim.notify(
                string.format("[neo-reviewer] Failed to delete AI output file: %s", output_file),
                vim.log.levels.WARN
            )
        end)
    end
end

---@param timer uv.uv_timer_t?
---@return nil
local function stop_timer(timer)
    if not timer then
        return
    end

    if not uv.is_closing(timer) then
        timer:stop()
        timer:close()
    end
end

---@param job NRAIJob
---@return nil
local function terminate_job(job)
    if job.handle and job.handle.kill and not uv.is_closing(job.handle) then
        pcall(job.handle.kill, job.handle, "sigterm")
    elseif job.pid and uv.kill then
        pcall(uv.kill, job.pid, 15)
    end

    if job.shutdown and not job.is_shutdown then
        pcall(job.shutdown, job, 124, 15)
    end
end

---@param command string
---@param code integer
---@param stderr_lines string[]
---@return string
local function build_job_failure(command, code, stderr_lines)
    local stderr = table.concat(stderr_lines, "\n")
    if stderr ~= "" then
        return command .. " failed: " .. stderr
    end

    return string.format("%s failed with exit code %d", command, code)
end

---@param review NRReview
---@param analysis NRAIAnalysis
---@return NRAIAnalysis, NRAIWalkthroughChangeRef[]
function M.ensure_full_coverage(review, analysis)
    analysis = normalize_steps_to_unique_change_blocks(review, analysis)
    local missing = collect_missing_change_blocks(review, analysis)
    if #missing == 0 then
        return analysis, missing
    end
    return append_placeholder_steps(analysis, missing), missing
end

---Run AI analysis on a PR review
---@param review NRReview
---@param callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
function M.analyze_pr(review, callback)
    local config = require("neo_reviewer.config")
    local prompt = M.build_prompt(review)
    local root = resolve_root(review)
    local timeout_ms = config.values.ai.timeout_ms

    ---@param prompt_text string
    ---@param run_callback fun(analysis: NRAIAnalysis|nil, err: string|nil)
    local function run_prompt(prompt_text, run_callback)
        local stdout_lines = {}
        local stderr_lines = {}
        local spec = config.build_ai_command(prompt_text)
        local completed = false
        ---@type uv.uv_timer_t?
        local timeout_timer = nil
        ---@type NRAIJob?
        local job

        local job_opts = {
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
                if completed then
                    return
                end

                completed = true
                stop_timer(timeout_timer)

                if code ~= 0 then
                    cleanup_output_file(spec)
                    run_callback(nil, build_job_failure(spec.command, code, stderr_lines))
                    return
                end

                local output, output_err = collect_command_output(spec, stdout_lines)
                if not output then
                    run_callback(nil, output_err)
                    return
                end

                local analysis, err = parse_response(output)
                run_callback(analysis, err)
            end),
        }

        if root and root ~= "" then
            job_opts.cwd = root
        end

        local ok, new_job_or_err = pcall(function()
            return Job:new(job_opts)
        end)
        if not ok then
            cleanup_output_file(spec)
            run_callback(nil, "Failed to initialize " .. spec.command .. ": " .. tostring(new_job_or_err))
            return
        end

        ---@cast new_job_or_err NRAIJob
        job = new_job_or_err

        if timeout_ms > 0 then
            timeout_timer = uv.new_timer()
            if not timeout_timer then
                cleanup_output_file(spec)
                run_callback(nil, "Failed to create AI timeout timer")
                return
            end

            timeout_timer:start(
                timeout_ms,
                0,
                vim.schedule_wrap(function()
                    if completed then
                        return
                    end

                    completed = true
                    stop_timer(timeout_timer)
                    if job then
                        terminate_job(job)
                    end
                    cleanup_output_file(spec)
                    run_callback(
                        nil,
                        string.format(
                            "%s timed out after %d ms. Increase `ai.timeout_ms` if this review needs longer.",
                            spec.command,
                            timeout_ms
                        )
                    )
                end)
            )
        end

        local started, start_err = pcall(function()
            job:start()
        end)
        if not started then
            completed = true
            stop_timer(timeout_timer)
            cleanup_output_file(spec)
            run_callback(nil, "Failed to start " .. spec.command .. ": " .. tostring(start_err))
        end
    end

    run_prompt(prompt, function(analysis, err)
        if not analysis or err then
            callback(nil, err)
            return
        end

        analysis = M.ensure_full_coverage(review, analysis)
        callback(analysis, nil)
    end)
end

return M
