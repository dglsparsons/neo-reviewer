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

**When changing logic, always consider:**
- Do existing tests cover the changed code paths?
- Are new tests needed for new functionality?
- Do fixtures need updating for new data structures?
- Run `make test` to verify changes don't break existing tests

If tests pass without modification after significant logic changes, that's a red flag - the new code paths likely aren't covered.

## Documentation

User-facing documentation lives in `doc/greviewer.txt` (Neovim help format).

**When adding or changing the public API, always update the docs:**
- New functions exposed via `require("greviewer")` → add to FUNCTIONS section
- New user commands (`:GReview*`) → add to COMMANDS section
- New configuration options → add to CONFIGURATION section
- Changed behavior → update relevant descriptions

Keep the docs in sync with `lua/greviewer/init.lua` (commands/functions) and `lua/greviewer/config.lua` (configuration options).

## Nix

`flake.nix` builds both CLI and plugin. Uses `src = ./.` which only includes git-tracked files - uncommitted changes won't appear in Nix builds.

## Git Operations

User handles git - don't commit unless explicitly asked.
