# greviewer

A Neovim plugin for reviewing GitHub pull requests directly in your editor.

## Features

- **Single-buffer inline diff view** - See the current file state with gutter indicators showing what changed
- **Expandable old code preview** - Toggle to see what code looked like before
- **Change navigation** - Jump between changes with customizable keybinds
- **Review comments** - Add comments directly from Neovim
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
    "your-username/greviewer",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
        require("greviewer").setup({})
    end,
}
```

### 2. Install the CLI tool

```bash
cd /path/to/greviewer
cargo install --path cli
```

Or build manually:

```bash
cd cli
cargo build --release
# Add target/release to your PATH, or copy the binary somewhere in PATH
```

### 3. Authenticate with GitHub

```bash
gh auth login
```

The plugin uses `gh auth token` to get your GitHub token, which handles SSO and MFA automatically.

## Configuration

```lua
require("greviewer").setup({
    cli_path = "greviewer",  -- Path to CLI binary
    signs = {
        add = "+",
        delete = "-",
        change = "~",
    },
    wrap_navigation = true,      -- Wrap at file boundaries
    auto_expand_deletes = false, -- Auto-expand deleted lines
})
```

## Keymaps

greviewer doesn't set any keymaps by default. Add your own:

```lua
-- Navigation
vim.keymap.set("n", "]c", function()
    require("greviewer").next_hunk()
end, { desc = "Next change" })

vim.keymap.set("n", "[c", function()
    require("greviewer").prev_hunk()
end, { desc = "Previous change" })

-- Toggle inline diff preview
vim.keymap.set("n", "<CR>", function()
    require("greviewer").toggle_inline()
end, { desc = "Toggle inline diff" })

-- Comments
vim.keymap.set("n", "<leader>cc", function()
    require("greviewer").add_comment()
end, { desc = "Add comment" })

-- File picker
vim.keymap.set("n", "<leader>cf", function()
    require("greviewer").show_file_picker()
end, { desc = "Show changed files" })
```

## Usage

1. Open a PR for review:
   ```
   :GReview https://github.com/owner/repo/pull/123
   ```

2. Navigate between changes with `]c` and `[c`

3. Press `<CR>` on a changed line to see the old code

4. Add a comment with `<leader>cc`

5. Switch files with `<leader>cf`

6. Close the review:
   ```
   :GReviewClose
   ```

## Commands

| Command | Description |
|---------|-------------|
| `:GReview {url}` | Open a PR for review |
| `:GReviewClose` | Close the review |
| `:GReviewFiles` | Open file picker |
| `:GReviewAuth` | Check auth status |

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
│  - Parses unified diffs into structured hunks           │
│  - Posts review comments                                │
│  - Auth via `gh auth token`                             │
└─────────────────────────────────────────────────────────┘
```

## License

MIT
