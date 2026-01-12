---@class NRSigns
---@field add string Sign character for additions
---@field delete string Sign character for deletions
---@field change string Sign character for changes

---@class NRThreadWindowKeys
---@field close string|string[] Key(s) to close the thread window
---@field reply string Key to reply to a comment
---@field toggle_old string Key to toggle old code display
---@field apply string Key to apply a suggestion

---@class NRThreadWindow
---@field keys NRThreadWindowKeys

---@class NRInputWindowKeys
---@field submit string Key to submit input
---@field cancel string Key to cancel input

---@class NRInputWindow
---@field keys NRInputWindowKeys

---@class NRConfig
---@field cli_path string Path to the neo-reviewer CLI binary
---@field signs NRSigns
---@field wrap_navigation boolean Whether to wrap around when navigating hunks
---@field auto_expand_deletes boolean Whether to auto-expand deleted lines
---@field thread_window NRThreadWindow
---@field input_window NRInputWindow

---@class NRPartialSigns
---@field add? string Sign character for additions
---@field delete? string Sign character for deletions
---@field change? string Sign character for changes

---@class NRPartialThreadWindowKeys
---@field close? string|string[] Key(s) to close the thread window
---@field reply? string Key to reply to a comment
---@field toggle_old? string Key to toggle old code display
---@field apply? string Key to apply a suggestion

---@class NRPartialThreadWindow
---@field keys? NRPartialThreadWindowKeys

---@class NRPartialInputWindowKeys
---@field submit? string Key to submit input
---@field cancel? string Key to cancel input

---@class NRPartialInputWindow
---@field keys? NRPartialInputWindowKeys

---@class NRPartialConfig
---@field cli_path? string Path to the neo-reviewer CLI binary
---@field signs? NRPartialSigns
---@field wrap_navigation? boolean Whether to wrap around when navigating hunks
---@field auto_expand_deletes? boolean Whether to auto-expand deleted lines
---@field thread_window? NRPartialThreadWindow
---@field input_window? NRPartialInputWindow

---@class NRConfigModule
---@field values NRConfig
---@field setup fun(opts?: NRPartialConfig)
local M = {}

---@type NRConfig
M.values = {
    cli_path = "neo-reviewer",
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
            toggle_old = "o",
            apply = "a",
        },
    },
    input_window = {
        keys = {
            submit = "<C-s>",
            cancel = "<Esc>",
        },
    },
}

---@param opts? NRPartialConfig
function M.setup(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
