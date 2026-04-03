local Job = require("plenary.job")
local uv = vim.uv or vim.loop

---@class NRProcessHandle: uv.uv_handle_t
---@field kill fun(self: NRProcessHandle, signal: string)

---@class NRWalkthroughJob
---@field handle? NRProcessHandle
---@field pid? integer
---@field is_shutdown? boolean
---@field shutdown? fun(self: NRWalkthroughJob, code?: integer, signal?: integer)
---@field start fun(self: NRWalkthroughJob)

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
- Be brief, concrete, and plain-language.
- Use 1-based, inclusive line numbers for anchors.

Seed context (may be empty):
%s

Return ONLY valid JSON (no markdown, no extra text):
{
  "overview": "1-3 short paragraphs",
  "steps": [
    {
      "title": "Short step title",
      "explanation": "1-4 sentences",
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
- Decide whether the request is best answered as a code walkthrough or a conceptual explanation.
- Always include at least one step, ordered for a human walkthrough.
- Use anchors when they help; use an empty anchors array for high-level explanations.
- If exact review diff block ids are already available, include them in change_blocks; otherwise use an empty array.
- Anchors should be tight (about 3-20 lines) and repo-relative.
- If you mention a specific file or function, include an anchor.
- Focus on the explanation; do not include follow-up questions.
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

---@param job NRWalkthroughJob
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
    local timeout_ms = config.values.ai.timeout_ms
    local completed = false
    ---@type uv.uv_timer_t?
    local timeout_timer = nil

    local job_opts = {
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
            if completed then
                return
            end

            completed = true
            stop_timer(timeout_timer)

            if code ~= 0 then
                cleanup_output_file(spec)
                callback(nil, build_job_failure(spec.command, code, stderr_lines))
                return
            end

            local output, output_err = collect_command_output(spec, stdout_lines)
            if not output then
                callback(nil, output_err)
                return
            end

            local walkthrough, err = M.parse_response(output)
            if not walkthrough then
                callback(nil, err)
                return
            end

            walkthrough.prompt = ctx.prompt
            walkthrough.root = ctx.root

            callback(walkthrough, nil)
        end),
    }

    local ok, new_job_or_err = pcall(function()
        return Job:new(job_opts)
    end)
    if not ok then
        cleanup_output_file(spec)
        callback(nil, "Failed to initialize " .. spec.command .. ": " .. tostring(new_job_or_err))
        return
    end

    ---@cast new_job_or_err NRWalkthroughJob
    ---@type NRWalkthroughJob
    local job = new_job_or_err
    if timeout_ms > 0 then
        timeout_timer = uv.new_timer()
        if not timeout_timer then
            cleanup_output_file(spec)
            callback(nil, "Failed to create AI timeout timer")
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
                terminate_job(job)
                cleanup_output_file(spec)
                callback(
                    nil,
                    string.format(
                        "%s timed out after %d ms. Increase `ai.timeout_ms` if this walkthrough needs longer.",
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
        callback(nil, "Failed to start " .. spec.command .. ": " .. tostring(start_err))
    end
end

return M
