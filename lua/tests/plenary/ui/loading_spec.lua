local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local helpers = require("plenary.helpers")

local function find_loading_buffer()
    local fallback = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "neo-reviewer-loading" then
            if vim.fn.bufwinid(buf) ~= -1 then
                return buf
            end
            fallback = fallback or buf
        end
    end
    return fallback
end

describe("neo_reviewer.ui.loading", function()
    local loading_ui

    before_each(function()
        package.loaded["neo_reviewer.plugin"] = nil
        package.loaded["neo_reviewer.ui.loading"] = nil
        require("neo_reviewer.plugin").register_preloads()
        loading_ui = require("neo_reviewer.ui.loading")
    end)

    after_each(function()
        loading_ui.close()
        helpers.clear_all_buffers()
    end)

    it("renders animated loading text in a scratch buffer", function()
        loading_ui.show({
            title = "Loading",
            message = "Please wait",
            interval_ms = 100,
        })

        local bufnr = assert(find_loading_buffer())
        local first_render = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        assert.is_truthy(first_render:find("Loading%."))
        assert.is_truthy(first_render:find("Please wait", 1, true))

        local changed = vim.wait(400, function()
            local current = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
            return current ~= first_render
        end, 20)

        assert.is_true(changed)
        assert.is_true(loading_ui.is_open())
    end)
end)
