# AGENTS.md

## Project Overview

`greviewer` is a Neovim plugin for reviewing GitHub PRs. Hybrid architecture: Rust CLI for GitHub API/diff parsing, Lua plugin for UI.

## Architecture

```
cli/           Rust CLI (greviewer-cli)
  src/
    main.rs        Entry point, subcommands: fetch, comment, comments, auth
    commands/      Command implementations
    github/        GitHub API client (octocrab), auth via `gh auth token`
    diff/          Unified diff parser → structured hunks with line positions

lua/greviewer/ Neovim plugin
  init.lua         Main entry, user commands (GReview, GReviewDone, GReviewFiles)
  cli.lua          Plenary.job wrapper for CLI + git helpers
  state.lua        Review session state
  config.lua       User configuration
  ui/
    signs.lua      Gutter indicators (+, -, ~) on changed lines
    virtual.lua    Expandable old code preview (virtual lines)
    comments.lua   Inline comment display + adding
    nav.lua        Cross-file hunk navigation
    buffer.lua     Buffer helper functions

tests/         Plenary test suite
  plenary/     Test files (*_spec.lua)
  fixtures/    Mock PR data
```

## Commands

```bash
# Run all tests
make test

# Format Rust code (required before committing)
cargo fmt --all

# Format Terraform (required before committing)
terraform fmt -recursive repo/

# Build CLI
cargo build -p greviewer-cli --release

# Build via Nix
nix build .#greviewer-cli
nix build .#greviewer-nvim
```

## Key Patterns

### Hunk Structure
The CLI parses unified diffs into `Hunk` structs with:
- `start`, `count` - hunk boundaries from @@ header
- `added_lines` - actual line numbers of additions (for signs/navigation)
- `deleted_at` - positions where deletions occurred
- `old_lines` - deleted content (for virtual line preview)

### Navigation
`nav.lua` navigates between hunk starts across all files. Uses `greviewer_file` buffer variable to identify current file.

### State Management
`state.lua` holds active review data. Buffer variables (`greviewer_file`, `greviewer_pr_url`) link buffers to review files.

### Lazy Requires
UI modules use lazy `require()` inside functions to avoid circular dependencies.

## Testing

Tests use plenary.nvim. Mock data in `tests/fixtures/mock_pr_data.lua`. Helpers in `tests/plenary/helpers.lua`.

Test buffers don't have real file paths - navigation code checks `greviewer_file` buffer variable for file matching.

## Nix

`flake.nix` builds both CLI and plugin. Uses `src = ./.` which only includes git-tracked files - uncommitted changes won't appear in Nix builds.

## Git Operations

User handles git - don't commit unless explicitly asked.
