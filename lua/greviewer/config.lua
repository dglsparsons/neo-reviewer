---@class GReviewerSigns
---@field add string Sign character for additions
---@field delete string Sign character for deletions
---@field change string Sign character for changes

---@class GReviewerThreadWindowKeys
---@field close string|string[] Key(s) to close the thread window
---@field reply string Key to reply to a comment
---@field toggle_old string Key to toggle old code display
---@field apply string Key to apply a suggestion

---@class GReviewerThreadWindow
---@field keys GReviewerThreadWindowKeys

---@class GReviewerInputWindowKeys
---@field submit string Key to submit input
---@field cancel string Key to cancel input

---@class GReviewerInputWindow
---@field keys GReviewerInputWindowKeys

---@class GReviewerConfig
---@field cli_path string Path to the greviewer CLI binary
---@field signs GReviewerSigns
---@field wrap_navigation boolean Whether to wrap around when navigating hunks
---@field auto_expand_deletes boolean Whether to auto-expand deleted lines
---@field thread_window GReviewerThreadWindow
---@field input_window GReviewerInputWindow

---@class GReviewerPartialSigns
---@field add? string Sign character for additions
---@field delete? string Sign character for deletions
---@field change? string Sign character for changes

---@class GReviewerPartialThreadWindowKeys
---@field close? string|string[] Key(s) to close the thread window
---@field reply? string Key to reply to a comment
---@field toggle_old? string Key to toggle old code display
---@field apply? string Key to apply a suggestion

---@class GReviewerPartialThreadWindow
---@field keys? GReviewerPartialThreadWindowKeys

---@class GReviewerPartialInputWindowKeys
---@field submit? string Key to submit input
---@field cancel? string Key to cancel input

---@class GReviewerPartialInputWindow
---@field keys? GReviewerPartialInputWindowKeys

---@class GReviewerPartialConfig
---@field cli_path? string Path to the greviewer CLI binary
---@field signs? GReviewerPartialSigns
---@field wrap_navigation? boolean Whether to wrap around when navigating hunks
---@field auto_expand_deletes? boolean Whether to auto-expand deleted lines
---@field thread_window? GReviewerPartialThreadWindow
---@field input_window? GReviewerPartialInputWindow

---@class GReviewerConfigModule
---@field values GReviewerConfig
---@field setup fun(opts?: GReviewerPartialConfig)
local M = {}

---@type GReviewerConfig
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

---@param opts? GReviewerPartialConfig
function M.setup(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
