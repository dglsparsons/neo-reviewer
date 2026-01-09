local M = {}

M.values = {
    cli_path = "greviewer",
    signs = {
        add = "+",
        delete = "-",
        change = "~",
    },
    wrap_navigation = true,
    auto_expand_deletes = false,
    thread_window = {
        keys = {
            close = { "q", "<Esc>" },
            reply = "r",
        },
    },
}

function M.setup(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
