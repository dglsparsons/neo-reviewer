---@class NRAI
---@field enabled boolean Whether AI analysis is enabled by default
---@field model string Model for AI CLI
---@field command string Command to invoke AI CLI
---@field reasoning_effort? string Reasoning effort hint for the AI CLI
---@field walkthrough_window NRAIWalkthroughWindow Walkthrough window configuration

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

---@class NRAIWalkthroughWindow
---@field height integer Minimum height of the walkthrough split (0 = auto)
---@field focus_on_open boolean Whether to focus the walkthrough window on open

---@class NRReviewDiff
---@field skip_noise_files boolean Whether to skip common lock/noise files in local diff reviews
---@field noise_files string[] Basenames to skip in local diff reviews when skip_noise_files is enabled

---@class NRConfig
---@field cli_path string Path to the neo-reviewer CLI binary
---@field signs NRSigns
---@field wrap_navigation boolean Whether to wrap around when navigating change blocks
---@field auto_expand_deletes boolean Whether to auto-expand deleted lines
---@field thread_window NRThreadWindow
---@field input_window NRInputWindow
---@field review_diff NRReviewDiff
---@field ai NRAI AI analysis configuration

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

---@class NRPartialAIWalkthroughWindow
---@field height? integer Minimum height of the walkthrough split (0 = auto)
---@field focus_on_open? boolean Whether to focus the walkthrough window on open

---@class NRPartialReviewDiff
---@field skip_noise_files? boolean Whether to skip common lock/noise files in local diff reviews
---@field noise_files? string[] Basenames to skip in local diff reviews when skip_noise_files is enabled

---@class NRPartialAI
---@field enabled? boolean Whether AI analysis is enabled by default
---@field model? string Model for AI CLI
---@field command? string Command to invoke AI CLI
---@field reasoning_effort? string Reasoning effort hint for the AI CLI
---@field walkthrough_window? NRPartialAIWalkthroughWindow Walkthrough window configuration

---@class NRPartialConfig
---@field cli_path? string Path to the neo-reviewer CLI binary
---@field signs? NRPartialSigns
---@field wrap_navigation? boolean Whether to wrap around when navigating change blocks
---@field auto_expand_deletes? boolean Whether to auto-expand deleted lines
---@field thread_window? NRPartialThreadWindow
---@field input_window? NRPartialInputWindow
---@field review_diff? NRPartialReviewDiff
---@field ai? NRPartialAI AI analysis configuration

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
    review_diff = {
        skip_noise_files = true,
        noise_files = {
            "pnpm-lock.yaml",
            "pnpm-lock.yml",
            "package-lock.json",
            "npm-shrinkwrap.json",
            "yarn.lock",
            "bun.lock",
            "bun.lockb",
            "Cargo.lock",
            "Gemfile.lock",
            "Pipfile.lock",
            "poetry.lock",
            "uv.lock",
            "pdm.lock",
            "composer.lock",
            "go.sum",
            "Gopkg.lock",
            "mix.lock",
            "pubspec.lock",
            "Podfile.lock",
            "Package.resolved",
            "packages.lock.json",
            "paket.lock",
            "gradle.lockfile",
            "deps.lock",
            "Chart.lock",
            "renv.lock",
            "conan.lock",
            "vcpkg-lock.json",
            "flake.lock",
            ".terraform.lock.hcl",
        },
    },
    ai = {
        enabled = false,
        model = "gpt-5.3-codex",
        command = "codex",
        reasoning_effort = "medium",
        walkthrough_window = {
            height = 0,
            focus_on_open = false,
        },
    },
}

---@class NRAICommandSpec
---@field command string
---@field args string[]
---@field writer? string

---@param prompt string
---@return NRAICommandSpec
function M.build_ai_command(prompt)
    local cmd = M.values.ai.command
    local model = M.values.ai.model
    if cmd == "codex" then
        local args = { "exec", "--model", model }
        local effort = M.values.ai.reasoning_effort
        if effort and effort ~= "" then
            table.insert(args, "--config")
            table.insert(args, string.format('model_reasoning_effort="%s"', effort))
        end
        table.insert(args, prompt)
        return { command = cmd, args = args }
    end

    return {
        command = cmd,
        args = { "run", "--model", model },
        writer = prompt,
    }
end

---@param opts? NRPartialConfig
function M.setup(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
