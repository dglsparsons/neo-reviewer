local state = require("neo_reviewer.state")

---@class NRCommentPosition
---@field line integer Line number
---@field side NRCommentSide Side of the diff

---@class NRParsedSuggestion
---@field before_text string[] Text before the suggestion block
---@field suggestion_lines string[] The suggested replacement lines
---@field after_text string[] Text after the suggestion block

---@class NRHighlight
---@field line integer 1-indexed line number
---@field hl string Highlight group name
---@field col_start integer Start column
---@field col_end integer End column (-1 for end of line)

---@class NRSuggestionInfo
---@field comment NRComment The comment containing the suggestion
---@field suggestion_lines string[] The suggested replacement lines
---@field display_start integer Start line in thread buffer (1-indexed)
---@field display_end integer End line in thread buffer (1-indexed)
---@field extmark_id? integer Extmark ID for toggle state

---@class NRMultilineInputOpts
---@field title? string Title for the input window

---@class NRCommentsModule
local M = {}

local ns = vim.api.nvim_create_namespace("nr_comments")
---@type integer?
local thread_win = nil
---@type integer?
local thread_buf = nil
---@type integer?
local input_win = nil
---@type integer?
local input_buf = nil

local function close_input_window()
    if input_win and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
    end
    if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
        vim.api.nvim_buf_delete(input_buf, { force = true })
    end
    input_win = nil
    input_buf = nil
    vim.cmd("stopinsert")
end

---@param opts NRMultilineInputOpts
---@param callback fun(body: string)
function M.open_multiline_input(opts, callback)
    local config = require("neo_reviewer.config")
    local keys = config.values.input_window.keys

    close_input_window()

    input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(input_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(input_buf, "filetype", "markdown")

    local width = math.min(80, math.floor(vim.o.columns * 0.8))
    local height = 10
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local title = opts.title or " Input "
    local submit_key = keys.submit
    local cancel_key = keys.cancel

    input_win = vim.api.nvim_open_win(input_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        footer = string.format(" %s: Submit | %s: Cancel ", submit_key, cancel_key),
        footer_pos = "center",
    })

    vim.api.nvim_win_set_option(input_win, "wrap", true)

    local function submit()
        local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
        local body = table.concat(lines, "\n")
        body = body:gsub("^%s*(.-)%s*$", "%1")
        close_input_window()
        if body ~= "" then
            callback(body)
        end
    end

    local function cancel()
        close_input_window()
    end

    vim.keymap.set("n", keys.submit, submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", keys.submit, submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("n", keys.cancel, cancel, { buffer = input_buf, nowait = true })

    vim.cmd("startinsert")
end

local function define_highlights()
    vim.api.nvim_set_hl(0, "NRComment", { fg = "#61afef", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRCommentSign", { fg = "#61afef", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRCommentRange", { fg = "#61afef", default = true })
    vim.api.nvim_set_hl(0, "NRThreadAuthor", { fg = "#e5c07b", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRThreadDate", { fg = "#5c6370", italic = true, default = true })
    vim.api.nvim_set_hl(0, "NRThreadBody", { fg = "#abb2bf", default = true })
    vim.api.nvim_set_hl(0, "NRThreadSeparator", { fg = "#3e4451", default = true })
    vim.api.nvim_set_hl(0, "NRThreadReply", { fg = "#98c379", default = true })
    vim.api.nvim_set_hl(0, "NRSuggestionNew", { fg = "#98c379", default = true })
    vim.api.nvim_set_hl(0, "NRSuggestionOld", { fg = "#e06c75", bg = "#3b2d2d", default = true })
    vim.api.nvim_set_hl(0, "NRSuggestionGutter", { fg = "#e5c07b", bold = true, default = true })
    vim.api.nvim_set_hl(0, "NRSuggestionBorder", { fg = "#5c6370", default = true })
end

---@param body? string
---@return NRParsedSuggestion?
local function parse_suggestion(body)
    if not body then
        return nil
    end

    ---@type string[]
    local before = {}
    ---@type string[]
    local suggestion_lines = {}
    ---@type string[]
    local after = {}
    local in_suggestion = false
    local found_suggestion = false

    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^```suggestion") then
            in_suggestion = true
            found_suggestion = true
        elseif in_suggestion and line:match("^```$") then
            in_suggestion = false
        elseif in_suggestion then
            table.insert(suggestion_lines, line)
        elseif found_suggestion then
            table.insert(after, line)
        else
            table.insert(before, line)
        end
    end

    if not found_suggestion then
        return nil
    end

    return {
        before_text = before,
        suggestion_lines = suggestion_lines,
        after_text = after,
    }
end

---@param file NRFile
---@param cursor_line integer
---@return NRCommentPosition
local function find_comment_position(file, cursor_line)
    local hunks = file.hunks or {}

    for _, hunk in ipairs(hunks) do
        local deleted_at = hunk.deleted_at or {}
        local deleted_old_lines = hunk.deleted_old_lines or {}
        for i, del_pos in ipairs(deleted_at) do
            if del_pos == cursor_line and deleted_old_lines[i] then
                return { line = deleted_old_lines[i], side = "LEFT" }
            end
        end
    end

    return { line = cursor_line, side = "RIGHT" }
end

---@param opts? NRAddCommentOpts
function M.add_at_cursor(opts)
    opts = opts or {}
    define_highlights()

    local buffer = require("neo_reviewer.ui.buffer")
    local file = buffer.get_current_file_from_buffer()

    if not file then
        vim.notify("Not in a review buffer", vim.log.levels.WARN)
        return
    end

    local is_local = state.is_local_review()
    local pr_url = not is_local and buffer.get_pr_url_from_buffer() or nil

    if not is_local and not pr_url then
        vim.notify("Not in a review buffer", vim.log.levels.WARN)
        return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    ---@type integer?
    local start_line = nil
    ---@type integer
    local end_line = cursor_line
    if opts.line1 and opts.line2 and opts.line1 ~= opts.line2 then
        start_line = math.min(opts.line1, opts.line2)
        end_line = math.max(opts.line1, opts.line2) --[[@as integer]]
    end

    local end_pos = find_comment_position(file, end_line --[[@as integer]])
    local start_pos = start_line and find_comment_position(file, start_line) or nil

    local title = start_line and string.format(" Comment (lines %d-%d) ", start_line, end_line) or " Comment "

    M.open_multiline_input({ title = title }, function(body)
        if is_local then
            M.add_local_comment(file, start_line, end_line --[[@as integer]], body)
        else
            ---@cast pr_url string
            M.add_pr_comment(file, pr_url, start_line, end_line --[[@as integer]], end_pos, start_pos, body)
        end
    end)
end

---@param file NRFile
---@param start_line? integer
---@param end_line integer
---@param body string
function M.add_local_comment(file, start_line, end_line, body)
    local comments_file = require("neo_reviewer.ui.comments_file")

    local success = comments_file.write(file.path, start_line or end_line, end_line, body)
    if not success then
        vim.notify("Failed to write comment", vim.log.levels.ERROR)
        return
    end

    vim.notify("Comment added to REVIEW_COMMENTS.md", vim.log.levels.INFO)

    ---@type NRComment
    local comment = {
        id = os.time(),
        path = file.path,
        line = end_line,
        start_line = start_line,
        side = "RIGHT",
        body = body,
        author = "you",
        created_at = os.date("%Y-%m-%dT%H:%M:%S") --[[@as string]],
    }
    state.add_comment(comment)

    local bufnr = vim.api.nvim_get_current_buf()
    M.show_comment(bufnr, comment)
end

---@param file NRFile
---@param pr_url string
---@param start_line? integer
---@param end_line integer
---@param end_pos NRCommentPosition
---@param start_pos? NRCommentPosition
---@param body string
function M.add_pr_comment(file, pr_url, start_line, end_line, end_pos, start_pos, body)
    vim.notify("Submitting comment...", vim.log.levels.INFO)

    local cli = require("neo_reviewer.cli")
    ---@type NRCommentData
    local comment_data = {
        path = file.path,
        line = end_pos.line,
        side = end_pos.side,
        body = body,
    }

    if start_pos then
        comment_data.start_line = start_pos.line
        comment_data.start_side = start_pos.side
    end

    cli.add_comment(pr_url, comment_data, function(data, err)
        if err then
            vim.notify("Failed to add comment: " .. err, vim.log.levels.ERROR)
            return
        end

        vim.notify("Comment added!", vim.log.levels.INFO)

        ---@type NRComment
        local comment = {
            id = data.comment_id,
            path = file.path,
            line = end_line,
            start_line = start_line,
            side = end_pos.side,
            start_side = start_pos and start_pos.side or nil,
            body = body,
            author = "you",
            created_at = os.date("%Y-%m-%dT%H:%M:%S") --[[@as string]],
            html_url = data.html_url or "",
        }
        state.add_comment(comment)

        local bufnr = vim.api.nvim_get_current_buf()
        M.show_comment(bufnr, comment)
    end)
end

---@param hunks? NRHunk[]
---@param old_line integer
---@return integer?
local function map_old_line_to_new(hunks, old_line)
    for _, hunk in ipairs(hunks or {}) do
        local deleted_old_lines = hunk.deleted_old_lines or {}
        for i, old_ln in ipairs(deleted_old_lines) do
            if old_ln == old_line then
                local deleted_at = hunk.deleted_at or {}
                if deleted_at[i] then
                    return deleted_at[i]
                end
            end
        end
    end
    return nil
end

---@param bufnr integer
---@param comment NRComment
---@param hunks? NRHunk[]
---@param reply_count? integer
function M.show_comment(bufnr, comment, hunks, reply_count)
    if type(comment.line) ~= "number" then
        return
    end

    local display_end_line = comment.line
    if comment.side == "LEFT" and hunks then
        local mapped = map_old_line_to_new(hunks, comment.line)
        if mapped then
            display_end_line = mapped
        end
    end

    ---@type integer?
    local display_start_line = nil
    if type(comment.start_line) == "number" then
        display_start_line = comment.start_line
        if comment.start_side == "LEFT" and hunks then
            local mapped = map_old_line_to_new(hunks, comment.start_line)
            if mapped then
                display_start_line = mapped
            end
        end
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local end_row = display_end_line - 1
    if end_row >= line_count then
        return
    end

    local display_body = comment.body
    if #display_body > 50 then
        display_body = display_body:sub(1, 47) .. "..."
    end
    display_body = display_body:gsub("\n", " ")

    local text = string.format(" %s: %s", comment.author, display_body)
    if reply_count and reply_count > 0 then
        text = text .. string.format(" (+%d %s)", reply_count, reply_count == 1 and "reply" or "replies")
    end

    if display_start_line and display_start_line < display_end_line then
        local start_row = display_start_line - 1
        if start_row >= 0 and start_row < line_count then
            for row = start_row, end_row do
                local bracket
                if row == start_row then
                    bracket = "┐"
                elseif row == end_row then
                    bracket = "┘"
                else
                    bracket = "│"
                end

                vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
                    virt_text = { { bracket, "NRCommentRange" } },
                    virt_text_pos = "right_align",
                    priority = 20,
                })
            end

            vim.api.nvim_buf_set_extmark(bufnr, ns, end_row, 0, {
                virt_text = { { text, "NRComment" } },
                virt_text_pos = "eol",
                priority = 20,
            })
        end
    else
        vim.api.nvim_buf_set_extmark(bufnr, ns, end_row, 0, {
            virt_text = { { text, "NRComment" } },
            virt_text_pos = "eol",
            sign_text = "",
            sign_hl_group = "NRCommentSign",
            priority = 20,
        })
    end
end

---@param comment NRComment
---@return boolean
local function is_reply(comment)
    return type(comment.in_reply_to_id) == "number"
end

---@param bufnr integer
---@param file_path string
function M.show_existing(bufnr, file_path)
    define_highlights()

    local file = state.get_file_by_path(file_path)
    local hunks = file and file.hunks or {}
    local comments = state.get_comments_for_file(file_path)

    ---@type NRComment[]
    local root_comments = {}
    ---@type table<integer|string, integer>
    local reply_counts = {}

    for _, comment in ipairs(comments) do
        if not is_reply(comment) then
            table.insert(root_comments, comment)
            reply_counts[comment.id] = 0
        end
    end

    for _, comment in ipairs(comments) do
        if is_reply(comment) and reply_counts[comment.in_reply_to_id] then
            reply_counts[comment.in_reply_to_id] = reply_counts[comment.in_reply_to_id] + 1
        end
    end

    for _, comment in ipairs(root_comments) do
        M.show_comment(bufnr, comment, hunks, reply_counts[comment.id])
    end
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---@param comment NRComment
---@param line integer
---@param hunks? NRHunk[]
---@return boolean
local function comment_matches_line(comment, line, hunks)
    local end_line = comment.line
    if type(end_line) ~= "number" then
        return false
    end

    ---@type integer?
    local start_line = comment.start_line
    if type(start_line) ~= "number" then
        start_line = nil
    end

    if comment.side == "LEFT" then
        end_line = map_old_line_to_new(hunks, comment.line) or end_line
    end

    if start_line and comment.start_side == "LEFT" then
        start_line = map_old_line_to_new(hunks, comment.start_line) or start_line
    end

    if start_line and start_line < end_line then
        return line >= start_line and line <= end_line
    else
        return end_line == line
    end
end

---@param file_path string
---@param line integer
---@param hunks? NRHunk[]
---@return NRComment[][]
local function get_threads_for_line(file_path, line, hunks)
    local comments = state.get_comments_for_file(file_path)
    ---@type NRComment[][]
    local threads = {}

    for _, comment in ipairs(comments) do
        if comment_matches_line(comment, line, hunks) and not is_reply(comment) then
            ---@type NRComment[]
            local thread = { comment }
            for _, reply in ipairs(comments) do
                if is_reply(reply) and reply.in_reply_to_id == comment.id then
                    table.insert(thread, reply)
                end
            end
            table.sort(thread, function(a, b)
                return (a.created_at or "") < (b.created_at or "")
            end)
            table.insert(threads, thread)
        end
    end

    if #threads == 0 then
        for _, comment in ipairs(comments) do
            if comment_matches_line(comment, line, hunks) then
                table.insert(threads, { comment })
            end
        end
    end

    return threads
end

---@param iso_date? string
---@return string
local function format_date(iso_date)
    if not iso_date then
        return ""
    end
    local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+)"
    local year, month, day, hour, min = iso_date:match(pattern)
    if year then
        return string.format("%s-%s-%s %s:%s", year, month, day, hour, min)
    end
    return iso_date
end

---@param threads NRComment[][]
---@param is_local_review boolean
---@return string[] lines
---@return NRHighlight[] highlights
---@return table<integer, NRComment> comment_positions
---@return NRSuggestionInfo[] suggestions
local function build_thread_lines(threads, is_local_review)
    ---@type string[]
    local lines = {}
    ---@type NRHighlight[]
    local highlights = {}
    ---@type table<integer, NRComment>
    local comment_positions = {}
    ---@type NRSuggestionInfo[]
    local suggestions = {}

    for thread_idx, thread in ipairs(threads) do
        if thread_idx > 1 then
            table.insert(lines, "")
            table.insert(lines, string.rep("─", 50))
            table.insert(highlights, { line = #lines, hl = "NRThreadSeparator", col_start = 0, col_end = -1 })
            table.insert(lines, "")
        end

        for comment_idx, comment in ipairs(thread) do
            local start_line_num = #lines + 1
            local is_reply_comment = comment_idx > 1
            local reply_marker = is_reply_comment and "  ↳ " or ""
            local reply_indent = is_reply_comment and "    " or ""

            local author_line = reply_marker .. "@" .. (comment.author or "unknown")
            if comment_idx == 1 and type(comment.start_line) == "number" and type(comment.line) == "number" then
                author_line = author_line .. string.format("  [lines %d-%d]", comment.start_line, comment.line)
            elseif comment_idx == 1 and type(comment.line) == "number" then
                author_line = author_line .. string.format("  [line %d]", comment.line)
            end
            table.insert(lines, author_line)
            table.insert(highlights, {
                line = #lines,
                hl = "NRThreadAuthor",
                col_start = #reply_marker,
                col_end = #author_line,
            })

            local date_line = reply_indent .. "  " .. format_date(comment.created_at)
            table.insert(lines, date_line)
            table.insert(highlights, {
                line = #lines,
                hl = "NRThreadDate",
                col_start = 0,
                col_end = -1,
            })

            table.insert(lines, "")

            local body = comment.body or ""
            local suggestion = parse_suggestion(body)

            if suggestion then
                for _, text_line in ipairs(suggestion.before_text) do
                    table.insert(lines, reply_indent .. "  " .. text_line)
                    table.insert(highlights, {
                        line = #lines,
                        hl = "NRThreadBody",
                        col_start = 0,
                        col_end = -1,
                    })
                end

                if #suggestion.before_text > 0 then
                    table.insert(lines, "")
                end

                table.insert(lines, reply_indent .. "  ┌─ Suggestion " .. string.rep("─", 35))
                table.insert(highlights, {
                    line = #lines,
                    hl = "NRSuggestionBorder",
                    col_start = 0,
                    col_end = -1,
                })

                local suggestion_start_line = #lines + 1
                for _, sugg_line in ipairs(suggestion.suggestion_lines) do
                    table.insert(lines, reply_indent .. "  ~ │ " .. sugg_line)
                    table.insert(highlights, {
                        line = #lines,
                        hl = "NRSuggestionGutter",
                        col_start = #reply_indent + 2,
                        col_end = #reply_indent + 3,
                    })
                    table.insert(highlights, {
                        line = #lines,
                        hl = "NRSuggestionBorder",
                        col_start = #reply_indent + 4,
                        col_end = #reply_indent + 5,
                    })
                    table.insert(highlights, {
                        line = #lines,
                        hl = "NRSuggestionNew",
                        col_start = #reply_indent + 6,
                        col_end = -1,
                    })
                end
                local suggestion_end_line = #lines

                table.insert(lines, reply_indent .. "  └" .. string.rep("─", 47))
                table.insert(highlights, {
                    line = #lines,
                    hl = "NRSuggestionBorder",
                    col_start = 0,
                    col_end = -1,
                })

                table.insert(suggestions, {
                    comment = comment,
                    suggestion_lines = suggestion.suggestion_lines,
                    display_start = suggestion_start_line,
                    display_end = suggestion_end_line,
                })

                if #suggestion.after_text > 0 then
                    table.insert(lines, "")
                    for _, text_line in ipairs(suggestion.after_text) do
                        table.insert(lines, reply_indent .. "  " .. text_line)
                        table.insert(highlights, {
                            line = #lines,
                            hl = "NRThreadBody",
                            col_start = 0,
                            col_end = -1,
                        })
                    end
                end
            else
                for body_line in (body .. "\n"):gmatch("([^\n]*)\n") do
                    table.insert(lines, reply_indent .. "  " .. body_line)
                    table.insert(highlights, {
                        line = #lines,
                        hl = "NRThreadBody",
                        col_start = 0,
                        col_end = -1,
                    })
                end
            end

            comment_positions[start_line_num] = comment

            if comment_idx < #thread then
                table.insert(lines, "")
            end
        end
    end

    local config = require("neo_reviewer.config")
    local keys = config.values.thread_window.keys
    local close_key = type(keys.close) == "table" and keys.close[1] or keys.close
    local toggle_key = type(keys.toggle_old) == "table" and keys.toggle_old[1] or keys.toggle_old
    local apply_key = type(keys.apply) == "table" and keys.apply[1] or keys.apply

    table.insert(lines, "")
    local help_line
    if is_local_review then
        help_line = string.format("[%s] Close", close_key)
    else
        local reply_key = type(keys.reply) == "table" and keys.reply[1] or keys.reply
        help_line = string.format("[%s] Reply  [%s] Close", reply_key, close_key)
    end
    if #suggestions > 0 then
        help_line = string.format("[%s] Toggle old  [%s] Apply  ", toggle_key, apply_key) .. help_line
    end
    table.insert(lines, help_line)
    table.insert(highlights, {
        line = #lines,
        hl = "NRThreadReply",
        col_start = 0,
        col_end = -1,
    })

    return lines, highlights, comment_positions, suggestions
end

local function close_thread_window()
    if thread_win and vim.api.nvim_win_is_valid(thread_win) then
        vim.api.nvim_win_close(thread_win, true)
    end
    if thread_buf and vim.api.nvim_buf_is_valid(thread_buf) then
        vim.api.nvim_buf_delete(thread_buf, { force = true })
    end
    thread_win = nil
    thread_buf = nil
end

---@param comment_positions table<integer, NRComment>
---@return NRComment?
local function get_comment_at_cursor(comment_positions)
    if not thread_buf or not vim.api.nvim_buf_is_valid(thread_buf) then
        return nil
    end

    local cursor_line = vim.api.nvim_win_get_cursor(thread_win)[1]

    ---@type NRComment?
    local closest_comment = nil
    local closest_line = 0
    for line, comment in pairs(comment_positions) do
        if line <= cursor_line and line > closest_line then
            closest_line = line
            closest_comment = comment
        end
    end

    return closest_comment
end

---@param comment NRComment
---@param pr_url string
local function prompt_reply(comment, pr_url)
    close_thread_window()

    M.open_multiline_input({ title = " Reply " }, function(body)
        vim.notify("Submitting reply...", vim.log.levels.INFO)

        local cli = require("neo_reviewer.cli")
        cli.reply_to_comment(pr_url, comment.id, body, function(data, err)
            if err then
                vim.notify("Failed to reply: " .. err, vim.log.levels.ERROR)
                return
            end

            vim.notify("Reply added!", vim.log.levels.INFO)

            ---@type NRComment
            local reply = {
                id = data.comment_id,
                path = comment.path,
                line = comment.line,
                side = comment.side or "RIGHT",
                body = body,
                author = "you",
                created_at = os.date("%Y-%m-%dT%H:%M:%S") --[[@as string]],
                html_url = data.html_url or "",
                in_reply_to_id = comment.id,
            }
            state.add_comment(reply)
        end)
    end)
end

---@param source_bufnr integer
---@param comment NRComment
---@return string[]
local function get_current_code_lines(source_bufnr, comment)
    local start_line = comment.start_line or comment.line
    local end_line = comment.line
    if not start_line or not end_line then
        return {}
    end

    local line_count = vim.api.nvim_buf_line_count(source_bufnr)
    if start_line > line_count or end_line > line_count then
        return {}
    end

    return vim.api.nvim_buf_get_lines(source_bufnr, start_line - 1, end_line, false)
end

---@param suggestions NRSuggestionInfo[]
---@return NRSuggestionInfo?
local function find_suggestion_at_cursor(suggestions)
    if not thread_win or not vim.api.nvim_win_is_valid(thread_win) then
        return nil
    end

    local cursor_line = vim.api.nvim_win_get_cursor(thread_win)[1]

    for _, sugg in ipairs(suggestions) do
        if cursor_line >= sugg.display_start and cursor_line <= sugg.display_end + 1 then
            return sugg
        end
    end

    if #suggestions == 1 then
        return suggestions[1]
    end

    return nil
end

---@param source_bufnr integer
---@param suggestions NRSuggestionInfo[]
local function toggle_old_code(source_bufnr, suggestions)
    if not thread_buf or not vim.api.nvim_buf_is_valid(thread_buf) then
        return
    end

    local sugg = find_suggestion_at_cursor(suggestions)
    if not sugg then
        vim.notify("No suggestion at cursor", vim.log.levels.INFO)
        return
    end

    local old_lines = get_current_code_lines(source_bufnr, sugg.comment)
    if #old_lines == 0 then
        vim.notify("Could not retrieve current code", vim.log.levels.WARN)
        return
    end

    if sugg.extmark_id then
        pcall(vim.api.nvim_buf_del_extmark, thread_buf, ns, sugg.extmark_id)
        sugg.extmark_id = nil
    else
        ---@type {[1]: string, [2]: string}[][]
        local virt_lines = {}
        for _, old_line in ipairs(old_lines) do
            table.insert(virt_lines, {
                { "    │ " .. old_line, "NRSuggestionOld" },
            })
        end

        sugg.extmark_id = vim.api.nvim_buf_set_extmark(thread_buf, ns, sugg.display_start - 1, 0, {
            virt_lines = virt_lines,
            virt_lines_above = true,
        })
    end
end

---@param source_bufnr integer
---@param suggestions NRSuggestionInfo[]
---@param file_path string
local function apply_suggestion(source_bufnr, suggestions, file_path)
    local sugg = find_suggestion_at_cursor(suggestions)
    if not sugg then
        vim.notify("No suggestion at cursor", vim.log.levels.INFO)
        return
    end

    local comment = sugg.comment
    local start_line = comment.start_line or comment.line
    local end_line = comment.line

    if not start_line or not end_line then
        vim.notify("Invalid suggestion line range", vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_buf_set_lines(source_bufnr, start_line - 1, end_line, false, sugg.suggestion_lines)

    close_thread_window()

    local comments = require("neo_reviewer.ui.comments")
    comments.clear(source_bufnr)
    comments.show_existing(source_bufnr, file_path)

    local signs = require("neo_reviewer.ui.signs")
    local file = state.get_file_by_path(file_path)
    signs.clear(source_bufnr)
    signs.place(source_bufnr, file and file.hunks or {})

    vim.notify(
        string.format(
            "Applied suggestion to line%s %d%s",
            start_line ~= end_line and "s" or "",
            start_line,
            start_line ~= end_line and ("-" .. end_line) or ""
        ),
        vim.log.levels.INFO
    )
end

function M.show_thread()
    define_highlights()

    local buffer = require("neo_reviewer.ui.buffer")
    local file = buffer.get_current_file_from_buffer()
    local is_local = state.is_local_review()
    local pr_url = not is_local and buffer.get_pr_url_from_buffer() or nil

    if not file then
        vim.notify("Not in a review buffer", vim.log.levels.WARN)
        return
    end

    if not is_local and not pr_url then
        vim.notify("Not in a review buffer", vim.log.levels.WARN)
        return
    end

    local source_bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local threads = get_threads_for_line(file.path, line, file.hunks)

    if #threads == 0 then
        vim.notify("No comments on this line", vim.log.levels.INFO)
        return
    end

    close_thread_window()

    local lines, highlights, comment_positions, suggestions = build_thread_lines(threads, is_local)

    thread_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(thread_buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(thread_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(thread_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(thread_buf, "filetype", "nr_thread")

    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(thread_buf, -1, hl.hl, hl.line - 1, hl.col_start, hl.col_end)
    end

    local width = math.min(80, math.floor(vim.o.columns * 0.8))
    local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    thread_win = vim.api.nvim_open_win(thread_buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Comment Thread ",
        title_pos = "center",
    })

    vim.api.nvim_win_set_option(thread_win, "wrap", true)
    vim.api.nvim_win_set_option(thread_win, "cursorline", true)

    local config = require("neo_reviewer.config")
    local keys = config.values.thread_window.keys

    ---@param key_config string|string[]
    ---@return string[]
    local function normalize_keys(key_config)
        if type(key_config) == "table" then
            return key_config
        end
        return { key_config }
    end

    for _, key in ipairs(normalize_keys(keys.close)) do
        vim.keymap.set("n", key, close_thread_window, { buffer = thread_buf, nowait = true })
    end

    if not is_local and pr_url then
        for _, key in ipairs(normalize_keys(keys.reply)) do
            vim.keymap.set("n", key, function()
                local comment = get_comment_at_cursor(comment_positions)
                if comment then
                    prompt_reply(comment, pr_url)
                else
                    vim.notify("No comment found at cursor", vim.log.levels.WARN)
                end
            end, { buffer = thread_buf, nowait = true })
        end
    end

    if #suggestions > 0 then
        for _, key in ipairs(normalize_keys(keys.toggle_old)) do
            vim.keymap.set("n", key, function()
                toggle_old_code(source_bufnr, suggestions)
            end, { buffer = thread_buf, nowait = true })
        end

        for _, key in ipairs(normalize_keys(keys.apply)) do
            vim.keymap.set("n", key, function()
                apply_suggestion(source_bufnr, suggestions, file.path)
            end, { buffer = thread_buf, nowait = true })
        end
    end
end

M.parse_suggestion = parse_suggestion

return M
