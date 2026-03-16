# AGENTS.md

## Why this file exists

- Keep non-obvious implementation learnings that save future effort.
- Prefer notes about pitfalls, tradeoffs, and validation patterns over things that are easy to rediscover from code.

## Prompt to update this file after future work

- After any substantial implementation, ask: `What did I learn that would save at least 30 minutes next time?`
- If the answer is non-empty, add concise bullets here in the most relevant section.

## Learned while implementing old-code preview behavior

- `toggle_prev_code()` is a global review-mode toggle: it flips `show_old_code` and applies to all hunks in applied review buffers, not just the currently selected change block.
- `ui/virtual.expand()` is used directly in tests and other call paths, so it must call `define_highlights()` itself; relying on `apply_mode_to_buffer()` or `toggle_review_mode()` leaves `NRVirtualDelete` undefined.
- Plugin-owned highlight groups that need to refresh in the current session should not use `default = true`; stale existing groups otherwise survive and make UI changes appear to have no effect.

## Learned while implementing Ask walkthrough navigation

- `next_change`/`prev_change` route through `ui/walkthrough.lua` when Ask is open, so anchor-level behavior must live in `next_step`/`prev_step`; changing `ui/nav.lua` alone will not affect Ask navigation.
- Ask walkthrough highlight changes need updates in both `lua/tests/plenary/ui/walkthrough_spec.lua` and `lua/tests/plenary/init_walkthrough_controls_spec.lua`; the former should also fix `vim.o.columns`/`vim.o.lines` so long file names do not wrap and create false-negative detail-pane assertions.

## Learned while implementing local diff noise filtering

- Filter `ReviewDiff` files before `state.set_local_review()` and before optional AI analysis so navigation, change counts, and AI walkthrough inputs stay consistent.
- Basename-based skipping is sufficient for lockfiles: matching both exact path and `"/" .. basename` suffix excludes nested lockfiles without adding glob parsing complexity.

## Learned while extending noise filtering to PR reviews

- Reapply `review_diff` noise filtering in both `ReviewPR` fetch and PR `ReviewSync` before `state.set_review()`; otherwise the initial review, sync refresh, and AI analysis drift onto different file sets.

## Learned while implementing ReviewDiff target modes

- Local diff review now combines tracked diffs and untracked-file patches in the Rust CLI (`git diff ...` plus `git ls-files --others --exclude-standard`); keep `--tracked-only` and `--cached-only` semantics in CLI, then apply Lua noise filtering after fetch as usual.

## Learned while implementing PR local diff sourcing

- `fetch` builds PR change blocks from local git (`git diff -w <base_sha>...<head_sha>`) instead of GitHub file patches; when commits are missing locally it attempts a targeted `git fetch` of base/head refs before failing.

## Learned while implementing ReviewSync for local diffs

- Store `ReviewDiff` selector options (`target`, `--cached-only`, `--uncached-only`, `--merge-base`, `--tracked-only`) on the active local review so `ReviewSync` can re-run the same diff mode instead of silently falling back to default `diff`.
- Do not carry `expanded_changes` extmark IDs across `ReviewSync`; extmarks are buffer-local and cleared by `state.clear_review()`, so stale IDs prevent old-code expansion from reapplying.
- Local diff comments are state-only, so both reopened buffers and local `ReviewSync` need to repopulate overlays from `review.comments`; PR-only redraw paths make comments appear to vanish while navigation state is still intact.

## Learned while fixing PR comment pagination and LEFT-side rendering

- `GET /pulls/{number}/comments` is paginated; `get_review_comments()` must follow `Link` header `rel="next"` (and should request `per_page=100`) or comments silently truncate on larger PRs.
- LEFT-side old-to-new mappings can legitimately resolve to `0` on full-file deletions; clamp mapped display lines into `[1, line_count]` before extmark placement to avoid out-of-range row errors.

## Learned while implementing autosync triggers

- Save-triggered PR sync should call CLI fetch with `--skip-comments` and preserve in-memory `review.comments`; this refreshes diff/highlights without comment API churn.
- Auto-sync timers are owned by `init.lua`; `state.clear_review()` should call `neo_reviewer._stop_autosync()` when available to avoid leaking periodic timers across teardown paths and tests.
- To keep the AI walkthrough panel stable during sync, plumb `keep_ai_ui` through `state.clear_review()` and re-render with `ai_ui.open()` after rebuilding review state.

## Learned while removing diff comment file persistence

- Local diff comments are state-only now; `:CopyComments` serializes current local root comments from review state.
- PR comment export needs thread-aware formatting from `review.comments`; flattening the list drops reply context, and orphan replies should still be emitted rather than silently discarded.

## Learned while implementing the AI pane split

- `topleft {width}vsplit` from the AI walkthrough pane creates a full-height column across the whole tab, not a split inside the bottom walkthrough area. Use `leftabove {width}vsplit` from the detail window to keep the navigator inside the walkthrough pane; otherwise the main editor window collapses and stacked walkthrough windows fail with `E36`.
- Transient loading panes need the same split-base exclusions as AI/Ask walkthrough panes; if `find_split_base_window()` can target `neo-reviewer-loading`, the final navigator/detail splits open relative to the loading scratch window instead of the editor layout.

## Learned while fixing preload registration startup ordering

- `plugin/neo_reviewer.vim` and user config can both hit `require("neo_reviewer")` during startup, so `init.lua` cannot trust `package.loaded["neo_reviewer.plugin"]` to be complete. If preload handlers are required before the module cache stabilizes, load the tracked `lua/neo_reviewer/plugin.lua` runtime file directly and run its top-level registration instead of waiting on `require()` state.
- When both the repo checkout and an installed plugin copy are on `runtimepath`, `vim.api.nvim_get_runtime_file("lua/neo_reviewer/plugin.lua", false)` can resolve the wrong `plugin.lua`. For preload recovery, derive the sibling tracked `plugin.lua` from the active source file path instead of asking runtimepath to choose.

## Learned while improving the AI step navigator

- `step_list_width` works better as a preferred width than a fixed one: cap the navigator against the available split width and wrap step titles across multiple navigator lines, otherwise larger defaults just crush the detail pane and single-line truncation makes reviewer-oriented step titles unreadable.
- For navigator overview text, keep the full content in the scratch buffer by pre-wrapping it into shorter lines instead of pre-truncating with ellipses. The window can still stay `nowrap`; buffer-level truncation is what makes the overview effectively unreadable in narrow layouts.
- The navigator overview wraps against `window width - 2`, so a default `step_list_width = 52` is what produces roughly 50 characters of overview text when the layout can spare the space. If the wrap point changes, update both the default and `get_target_nav_width()`.

## Learned while simplifying AI PR analysis

- The second AI coverage pass adds a full extra model roundtrip for marginal cleanup value. With a prompt that already asks for exact change-block coverage, a better tradeoff is one AI response plus local placeholder steps for any uncovered blocks, and prompt guidance should explicitly ban filler phrases like `"This matters because"` so the detail pane reads tightly.

## Learned while smoothing ReviewSync UI refresh

- For AI review panes, re-rendering existing split buffers during sync should preserve current window sizes; reusing `open()` without a layout-preserving option causes background refreshes to resize walkthrough splits.

## Learned while hardening comment export against JSON nulls

- `vim.json.decode()` turns JSON `null` into truthy `vim.NIL` userdata, so `comment.start_line or comment.line` is unsafe on decoded PR comment payloads. Normalize optional numeric fields with an explicit `type(value) == "number"` check before formatting ranges or applying suggestions.

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
nix build .#neo-reviewer --out-link result-cli
nix build .#neo-reviewer-nvim --out-link result-nvim

# Run a single Nix check without rewriting ./result
./scripts/build-check lua-tests
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

For a single check, prefer `./scripts/build-check <name>` or `nix build .#checks.<system>.<name> --no-link` so ad hoc check runs do not rewrite `./result`.

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
- Add checks to `flake.nix` and run via `./scripts/build-check <name>` or `nix flake check`

## Lua Coding Standards

- **Type Annotations:** Use LuaCATS (`---@param`, `---@return`, `---@type`) for ALL functions and complex variables.
- **Classes:** Define plugin modules and configuration objects using `---@class`.
- **LSP Compatibility:** Ensure all annotations are compatible with `lua-language-server`.
- **Strictness:** Favor explicit types over `any`.

## Git Operations

User handles git - don't commit unless explicitly asked.
