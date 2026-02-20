# neo-reviewer

A Neovim plugin for reviewing GitHub pull requests directly in your editor.

## Features

- **Single-buffer inline diff view** - See the current file state with gutter indicators showing what changed
- **Expandable old code preview** - Toggle to see what code looked like before
- **Change navigation** - Jump between changes with customizable keybinds
- **Review comments** - Add comments directly from Neovim
- **Thread actions** - View, reply, edit, and delete comments from the thread window
- **View existing comments** - See PR comments inline
- **Telescope integration** - Quick file switching with Telescope

## Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional)
- GitHub authentication via `gh` CLI

## Installation

### 1. Install the plugin

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "dglsparsons/neo-reviewer",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
        require("neo_reviewer").setup({})
    end,
}
```

### 2. Install the CLI tool

**Using Cargo (from git):**
```bash
cargo install --git https://github.com/dglsparsons/neo-reviewer neo-reviewer
```

**Using Nix:**
```bash
nix profile install github:dglsparsons/neo-reviewer
```

**From source:**
```bash
git clone https://github.com/dglsparsons/neo-reviewer
cd neo-reviewer
cargo install --path cli
```

### 3. Authenticate with GitHub

```bash
gh auth login
```

The plugin uses `gh auth token` to get your GitHub token, which handles SSO and MFA automatically.

## Configuration

```lua
local cli_path = "neo-reviewer"

require("neo_reviewer").setup({
    cli_path = cli_path,  -- Path to CLI binary
    signs = {
        add = "+",
        delete = "-",
        change = "~",
    },
    wrap_navigation = true,      -- Wrap at file boundaries
    auto_expand_deletes = false, -- Auto-expand deleted lines
    thread_window = {
        keys = {
            reply = "r",
            edit = "e",
            delete = "d",
        },
    },
    review_diff = {
        skip_noise_files = true,  -- Skip common lock/noise files by default
        noise_files = {
            "pnpm-lock.yaml",
            "Cargo.lock",
        },
    },
})
```

## Keymaps

neo-reviewer doesn't set any keymaps by default. Add your own:

```lua
local nr = require("neo_reviewer")
local opts = { silent = true, noremap = true }

-- Review lifecycle
vim.keymap.set("n", ",dr", ":ReviewPR<CR>", vim.tbl_extend("force", opts, { desc = "Review PR" }))
vim.keymap.set("n", ",dd", nr.review_diff, vim.tbl_extend("force", opts, { desc = "Review local diff" }))
vim.keymap.set("n", ",dq", nr.done, vim.tbl_extend("force", opts, { desc = "Close review" }))
vim.keymap.set("n", ",ds", nr.sync, vim.tbl_extend("force", opts, { desc = "Sync review" }))

-- Navigation
vim.keymap.set("n", ",dn", nr.next_change, vim.tbl_extend("force", opts, { desc = "Next change" }))
vim.keymap.set("n", ",dp", nr.prev_change, vim.tbl_extend("force", opts, { desc = "Prev change" }))
vim.keymap.set("n", ",dj", nr.next_comment, vim.tbl_extend("force", opts, { desc = "Next comment" }))
vim.keymap.set("n", ",dk", nr.prev_comment, vim.tbl_extend("force", opts, { desc = "Prev comment" }))

-- Interaction
vim.keymap.set("n", ",dc", nr.add_comment, vim.tbl_extend("force", opts, { desc = "Add comment" }))
vim.keymap.set("v", ",dc", ":AddComment<CR>", vim.tbl_extend("force", opts, { desc = "Add comment on selection" }))
vim.keymap.set("n", ",dv", nr.show_comment, vim.tbl_extend("force", opts, { desc = "View comment thread" }))
vim.keymap.set("n", ",do", nr.toggle_prev_code, vim.tbl_extend("force", opts, { desc = "Toggle old code" }))
vim.keymap.set("n", ",df", nr.show_file_picker, vim.tbl_extend("force", opts, { desc = "File picker" }))

-- AI
vim.keymap.set("n", ",di", nr.toggle_ai_feedback, vim.tbl_extend("force", opts, { desc = "Toggle AI summary" }))

-- Submit
vim.keymap.set("n", ",da", nr.approve, vim.tbl_extend("force", opts, { desc = "Approve PR" }))
vim.keymap.set("n", ",dx", nr.request_changes, vim.tbl_extend("force", opts, { desc = "Request changes" }))
```

## Usage

1. Open a PR for review:
   ```
   :ReviewPR https://github.com/owner/repo/pull/123
   ```

2. Navigate between changes with `]c` and `[c`

3. Press `<CR>` (or your old-code toggle mapping) to show/hide old code previews

4. Add a comment with `<leader>cc`

5. Switch files with `<leader>cf`

6. Close the review with `:ReviewDone` (or submit with `:Approve`/`:RequestChanges`)

7. Start a codebase exploration with `:Ask` (prompts for a question/theme)

## Commands

| Command | Description |
|---------|-------------|
| `:ReviewPR {url}` | Open a PR for review |
| `:ReviewDiff` | Review local git diff (skips configured noise files by default) |
| `:Ask` | AI-guided codebase exploration |
| `:AddComment` | Add a review comment |
| `:Approve` | Approve the PR |
| `:RequestChanges` | Request changes on the PR |
| `:ReviewDone` | End the review session without submitting |
| `:ReviewSync` | Sync PR review with GitHub |

## How it works

```
┌─────────────────────────────────────────────────────────┐
│                    Neovim Plugin                        │
│                                                         │
│  - Renders file content in buffer                       │
│  - Shows gutter signs for changes (+, -, ~)             │
│  - Virtual lines for inline old code preview            │
│  - Extmarks for comment display                         │
└───────────────────────┬─────────────────────────────────┘
                        │ JSON over stdio
                        ▼
┌─────────────────────────────────────────────────────────┐
│                    Rust CLI                             │
│                                                         │
│  - Fetches PR data from GitHub API                      │
│  - Parses unified diffs into change blocks              │
│  - Posts review comments                                │
│  - Auth via `gh auth token`                             │
└─────────────────────────────────────────────────────────┘
```

## License

MIT
