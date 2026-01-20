---@class NRPluginModule
local M = {}

---@return nil
function M.setup()
    vim.api.nvim_create_autocmd("VimEnter", {
        callback = function()
            if vim.fn.argc() > 0 then
                local arg = vim.fn.argv(0)
                if type(arg) == "string" and arg:match("github%.com/.+/pull/%d+") then
                    vim.defer_fn(function()
                        require("neo_reviewer").open_url(arg)
                    end, 100)
                end
            end
        end,
        once = true,
    })
end

return M
