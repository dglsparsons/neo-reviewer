---@class NRAIUIModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_ai")

local hl_groups_defined = false

local function define_highlights()
    if hl_groups_defined then
        return
    end
    hl_groups_defined = true

    vim.api.nvim_set_hl(0, "NRAIAnnotation", { fg = "#7c8f8f", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIConfidence5", { fg = "#98c379", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIConfidence4", { fg = "#61afef", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIConfidence3", { fg = "#e5c07b", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIConfidence2", { fg = "#d19a66", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRAIConfidence1", { fg = "#e06c75", italic = true, default = true })
end

---Get highlight group for confidence level
---@param confidence integer
---@return string
local function get_confidence_hl(confidence)
    return "NRAIConfidence" .. math.max(1, math.min(5, confidence))
end

---Truncate string to max length with ellipsis
---@param str string
---@param max_len integer
---@return string
local function truncate(str, max_len)
    if #str <= max_len then
        return str
    end
    return str:sub(1, max_len - 3) .. "..."
end

---Build virtual text for an AI annotation
---@param ai_hunk NRAIHunk
---@return table[] virt_text chunks
local function build_virt_text(ai_hunk)
    local hl = get_confidence_hl(ai_hunk.confidence)

    if ai_hunk.context then
        local context = truncate(ai_hunk.context, 80)
        return {
            { " ", "Normal" },
            { string.format("[%d/5]", ai_hunk.confidence), hl },
            { " " .. context, "NRAIAnnotation" },
        }
    else
        return {
            { " ", "Normal" },
            { string.format("[%d/5]", ai_hunk.confidence), hl },
        }
    end
end

---Apply AI annotations as virtual text to a buffer
---@param bufnr integer
---@param file NRFile
function M.apply(bufnr, file)
    define_highlights()

    local state = require("neo_reviewer.state")
    local analysis = state.get_ai_analysis()
    if not analysis then
        return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for _, ai_hunk in ipairs(analysis.hunk_order) do
        if ai_hunk.file == file.path then
            local hunk = file.hunks[ai_hunk.hunk_index + 1]
            if hunk then
                -- Skip annotation for trivial hunks (5/5 with no context)
                if ai_hunk.confidence == 5 and not ai_hunk.context then
                    goto continue
                end

                local first_add = hunk.added_lines and hunk.added_lines[1]
                local first_del = hunk.deleted_at and hunk.deleted_at[1]
                local line = nil
                if first_add and first_del then
                    line = math.min(first_add, first_del)
                else
                    line = first_add or first_del
                end

                if line and line >= 1 and line <= line_count then
                    local virt_text = build_virt_text(ai_hunk)
                    vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
                        virt_text = virt_text,
                        virt_text_pos = "eol",
                        priority = 5,
                    })
                end
            end
            ::continue::
        end
    end
end

---Clear AI annotations from a buffer
---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---Get AI annotation for the hunk at cursor position
---@param bufnr integer
---@return NRAIHunk|nil
function M.get_annotation_at_cursor(bufnr)
    local state = require("neo_reviewer.state")
    local analysis = state.get_ai_analysis()
    if not analysis then
        return nil
    end

    local ok, file = pcall(vim.api.nvim_buf_get_var, bufnr, "nr_file")
    if not ok or not file then
        return nil
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    for _, ai_hunk in ipairs(analysis.hunk_order) do
        if ai_hunk.file == file.path then
            local hunk = file.hunks[ai_hunk.hunk_index + 1]
            if hunk then
                local first_add = hunk.added_lines and hunk.added_lines[1]
                local first_del = hunk.deleted_at and hunk.deleted_at[1]
                local hunk_start = nil
                if first_add and first_del then
                    hunk_start = math.min(first_add, first_del)
                else
                    hunk_start = first_add or first_del
                end

                local hunk_end = hunk.start and (hunk.start + (hunk.count or 1) - 1) or hunk_start

                if hunk_start and hunk_end and cursor_line >= hunk_start and cursor_line <= hunk_end then
                    return ai_hunk
                end
            end
        end
    end

    return nil
end

---Build confidence bar visualization
---@param confidence integer
---@return string
local function build_confidence_bar(confidence)
    local filled = string.rep("█", confidence)
    local empty = string.rep("░", 5 - confidence)
    return filled .. empty
end

---Show floating window with AI analysis details for hunk at cursor
function M.show_details()
    define_highlights()

    local state = require("neo_reviewer.state")
    local analysis = state.get_ai_analysis()
    if not analysis then
        vim.notify("No AI analysis available", vim.log.levels.INFO)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local ai_hunk = M.get_annotation_at_cursor(bufnr)
    if not ai_hunk then
        vim.notify("No AI annotation at cursor", vim.log.levels.INFO)
        return
    end

    local lines = {}
    local max_width = 60

    table.insert(lines, "PR Goal: " .. analysis.goal)
    table.insert(lines, "")

    if analysis.confidence then
        local reason = analysis.confidence_reason or ""
        table.insert(lines, string.format("PR Confidence: %d/5 - %s", analysis.confidence, reason))
        table.insert(lines, "")
    end

    if analysis.removed_abstractions and #analysis.removed_abstractions > 0 then
        table.insert(lines, "Removed:")
        for _, abstraction in ipairs(analysis.removed_abstractions) do
            table.insert(lines, "  • " .. abstraction)
        end
        table.insert(lines, "")
    end

    if analysis.new_abstractions and #analysis.new_abstractions > 0 then
        table.insert(lines, "New:")
        for _, abstraction in ipairs(analysis.new_abstractions) do
            table.insert(lines, "  • " .. abstraction)
        end
    end

    -- Skip hunk-specific section for trivial hunks (5/5 with no context)
    if ai_hunk.confidence ~= 5 or ai_hunk.context then
        table.insert(lines, "")
        table.insert(lines, "")
        table.insert(lines, string.format("── This Change: %d/5 ──", ai_hunk.confidence))
        table.insert(lines, "")

        if ai_hunk.context then
            for line in ai_hunk.context:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
        end
    end

    local wrapped_lines = {}
    for _, line in ipairs(lines) do
        if #line > max_width then
            local remaining = line
            while #remaining > 0 do
                local chunk = remaining:sub(1, max_width)
                local space_pos = chunk:reverse():find(" ")
                if space_pos and #remaining > max_width then
                    chunk = chunk:sub(1, max_width - space_pos + 1)
                end
                table.insert(wrapped_lines, chunk)
                remaining = remaining:sub(#chunk + 1):gsub("^%s+", "")
            end
        else
            table.insert(wrapped_lines, line)
        end
    end

    local width = max_width
    local height = #wrapped_lines

    local win_width = vim.api.nvim_win_get_width(0)
    local win_height = vim.api.nvim_win_get_height(0)
    local row = math.floor((win_height - height) / 2)
    local col = math.floor((win_width - width) / 2)

    local float_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, wrapped_lines)
    vim.bo[float_buf].modifiable = false
    vim.bo[float_buf].bufhidden = "wipe"

    local float_win = vim.api.nvim_open_win(float_buf, true, {
        relative = "win",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " AI Analysis ",
        title_pos = "center",
    })

    vim.wo[float_win].wrap = true
    vim.wo[float_win].cursorline = false

    local close_keys = { "q", "<Esc>" }
    for _, key in ipairs(close_keys) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_is_valid(float_win) then
                vim.api.nvim_win_close(float_win, true)
            end
        end, { buffer = float_buf, nowait = true })
    end
end

return M
