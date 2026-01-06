local M = {}

function M.create_test_buffer(lines, opts)
    opts = opts or {}
    local bufnr = vim.api.nvim_create_buf(false, true)

    if type(lines) == "string" then
        lines = vim.split(lines, "\n")
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    if opts.filetype then
        vim.bo[bufnr].filetype = opts.filetype
    end

    if opts.set_current ~= false then
        vim.api.nvim_set_current_buf(bufnr)
    end

    return bufnr
end

function M.delete_buffer(bufnr)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
end

function M.clear_all_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
end

function M.set_cursor(line, col)
    col = col or 0
    vim.api.nvim_win_set_cursor(0, { line, col })
end

function M.get_cursor()
    return vim.api.nvim_win_get_cursor(0)
end

function M.get_extmarks(bufnr, ns_name)
    local ns = vim.api.nvim_create_namespace(ns_name)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

function M.wait(ms)
    vim.wait(ms or 10, function()
        return false
    end)
end

function M.deep_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = M.deep_copy(v)
    end
    return copy
end

function M.assert_table_eq(expected, actual, path)
    path = path or "root"
    local assert = require("luassert")

    if type(expected) ~= type(actual) then
        assert.are.equal(type(expected), type(actual), "Type mismatch at " .. path)
        return
    end

    if type(expected) ~= "table" then
        assert.are.equal(expected, actual, "Value mismatch at " .. path)
        return
    end

    for k, v in pairs(expected) do
        M.assert_table_eq(v, actual[k], path .. "." .. tostring(k))
    end

    for k, _ in pairs(actual) do
        if expected[k] == nil then
            assert.fail("Unexpected key at " .. path .. "." .. tostring(k))
        end
    end
end

function M.capture_notifications()
    local notifications = {}
    local original_notify = vim.notify

    vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
    end

    return {
        get = function()
            return notifications
        end,
        restore = function()
            vim.notify = original_notify
        end,
        clear = function()
            notifications = {}
        end,
    }
end

return M
