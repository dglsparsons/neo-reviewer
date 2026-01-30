# AGENTS.md

## Project Overview

`neo-reviewer` is a Neovim plugin for reviewing GitHub PRs. Hybrid architecture: Rust CLI for GitHub API/diff parsing, Lua plugin for UI.

## Architecture

```
cli/           Rust CLI (neo-reviewer)
  src/
    main.rs        Entry point, subcommands: fetch, comment, comments, auth
    commands/      Command implementations
    github/        GitHub API client (octocrab), auth via `gh auth token`
    diff/          Unified diff parser → structured hunks with line positions

lua/neo_reviewer/ Neovim plugin
  init.lua         Main entry, user commands (ReviewPR, ReviewDiff, AddComment, etc.)
  cli.lua          Plenary.job wrapper for CLI + git helpers
  state.lua        Review session state
  config.lua       User configuration
  ui/
    signs.lua      Gutter indicators (+, -, ~) on changed lines
    virtual.lua    Expandable old code preview (virtual lines)
    comments.lua   Inline comment display + adding
    nav.lua        Cross-file hunk navigation
    buffer.lua     Buffer helper functions

lua/tests/     Plenary test suite
  plenary/     Test files (*_spec.lua)
  fixtures/    Mock PR data
```

## Commands

```bash
# Run all checks (Rust + Lua linting/formatting + tests)
nix flake check

# Format Rust code (required before committing)
cargo fmt --all

# Format Lua code (required before committing)
stylua lua/

# Format Terraform (required before committing)
terraform fmt -recursive repo/

# Build CLI
cargo build -p neo-reviewer --release

# Build via Nix
nix build .#neo-reviewer
nix build .#neo-reviewer-nvim
```

## Key Patterns

### Hunk Structure
The CLI parses unified diffs into `Hunk` structs with:
- `start`, `count` - hunk boundaries from @@ header
- `added_lines` - actual line numbers of additions (for signs/navigation)
- `deleted_at` - positions where deletions occurred
- `old_lines` - deleted content (for virtual line preview)

### Navigation
`nav.lua` navigates between hunk starts across all files. Uses `nr_file` buffer variable to identify current file.

### State Management
`state.lua` holds active review data. Buffer variables (`nr_file`, `nr_pr_url`) link buffers to review files.

### Lazy Requires
UI modules use lazy `require()` inside functions to avoid circular dependencies.

## Testing

Tests use plenary.nvim. Mock data in `lua/tests/fixtures/mock_pr_data.lua`. Helpers in `lua/tests/plenary/helpers.lua`.

Test buffers don't have real file paths - navigation code checks `nr_file` buffer variable for file matching.

**ALWAYS write tests for new functionality.** This is not optional. When adding new functions, commands, or features:
1. Create a new `*_spec.lua` file or add to an existing one
2. Test validation/error cases (invalid inputs, missing state, edge cases)
3. Test the happy path behavior
4. Use stubs/mocks for external dependencies (CLI calls, vim APIs where needed)

**When changing existing logic:**
- Verify existing tests still pass
- Add tests for any new code paths
- Update fixtures if data structures changed

Always run `nix flake check` yourself before considering any change complete. Do not recommend it to the user in these cases—execute it and report results. If tests pass without modification after significant logic changes, that's a red flag - the new code paths likely aren't covered.

## Documentation

User-facing documentation lives in `doc/neo_reviewer.txt` (Neovim help format).

**When adding or changing the public API, always update the docs:**
- New functions exposed via `require("neo_reviewer")` → add to FUNCTIONS section
- New user commands (`:Review*`, `:AddComment`, etc.) → add to COMMANDS section
- New configuration options → add to CONFIGURATION section
- Changed behavior → update relevant descriptions

Keep the docs in sync with `lua/neo_reviewer/init.lua` (commands/functions) and `lua/neo_reviewer/config.lua` (configuration options).

## Nix

`flake.nix` builds both CLI and plugin. Uses `src = ./.` which only includes git-tracked files - uncommitted changes won't appear in Nix builds.

### Checks

`nix flake check` runs all linting/formatting checks and tests:
- `clippy` - Rust lints
- `fmt` - Rust formatting
- `lua-lint` - lua-language-server diagnostics
- `lua-fmt` - stylua formatting
- `lua-tests` - Plenary test suite
- `rust-tests` - Rust test suite

**Always run `nix flake check` yourself before considering any change complete.** Do not recommend it to the user—execute it and report results. All checks MUST pass. This includes:
- Zero Lua diagnostics (warnings are errors)
- Zero Clippy warnings
- Properly formatted code

If diagnostics fail, fix them before moving on. Common Lua diagnostic fixes:
- `need-check-nil`: Add nil guards (e.g., `value or {}`, `if value then`)
- `undefined-field`: Add missing fields to type stubs in `lua/stubs/`
- `redundant-parameter`: Check function signature matches usage

### CI

GitHub Actions use Nix for reproducible builds. When adding new CI jobs, prefer Nix over manual tool installation:
- Use `DeterminateSystems/nix-installer-action` and `magic-nix-cache-action`
- Add checks to `flake.nix` and run via `nix build .#checks...` or `nix flake check`

## Lua Coding Standards

- **Type Annotations:** Use LuaCATS (`---@param`, `---@return`, `---@type`) for ALL functions and complex variables.
- **Classes:** Define plugin modules and configuration objects using `---@class`.
- **LSP Compatibility:** Ensure all annotations are compatible with `lua-language-server`.
- **Strictness:** Favor explicit types over `any`.

## Git Operations

User handles git - don't commit unless explicitly asked.
