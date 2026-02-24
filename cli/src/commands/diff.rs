use anyhow::{Result, anyhow};
use regex::Regex;
use serde::Serialize;
use std::process::Command;

use crate::diff::parser::parse_patch;
use crate::github::types::{FileStatus, ReviewFile};

const IGNORE_WHITESPACE_CHANGES: bool = true;

#[derive(Debug, Clone, Default)]
pub struct LocalDiffCliOpts {
    pub target: Option<String>,
    pub cached_only: bool,
    pub uncached_only: bool,
    pub merge_base: bool,
    pub tracked_only: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalDiffMode {
    All,
    CachedOnly,
    UncachedOnly,
}

#[derive(Debug, Serialize)]
pub struct DiffResponse {
    pub files: Vec<ReviewFile>,
    pub git_root: String,
}

pub fn run(opts: LocalDiffCliOpts) -> Result<()> {
    let response = get_local_diff(opts, IGNORE_WHITESPACE_CHANGES)?;
    println!("{}", serde_json::to_string(&response)?);
    Ok(())
}

pub(crate) fn get_local_diff(
    opts: LocalDiffCliOpts,
    ignore_whitespace: bool,
) -> Result<DiffResponse> {
    let git_root = get_git_root()?;
    let mode = parse_local_diff_mode(opts.cached_only, opts.uncached_only)?;
    let diff_target = resolve_local_diff_target(opts.target.as_deref(), mode, opts.merge_base)?;
    let tracked_diff_output = get_git_diff(diff_target.as_deref(), ignore_whitespace, mode)?;

    let mut files = if tracked_diff_output.is_empty() {
        Vec::new()
    } else {
        parse_git_diff(&tracked_diff_output)?
    };

    if should_include_untracked(mode, opts.tracked_only) {
        files.extend(get_untracked_review_files(ignore_whitespace)?);
    }

    Ok(DiffResponse { files, git_root })
}

pub(crate) fn get_pr_review_files(
    base_sha: &str,
    head_sha: &str,
    ignore_whitespace: bool,
) -> Result<Vec<ReviewFile>> {
    let diff_target = build_pr_diff_target(base_sha, head_sha);
    let diff_output = get_git_diff(Some(&diff_target), ignore_whitespace, LocalDiffMode::All)?;

    if diff_output.is_empty() {
        return Ok(Vec::new());
    }

    parse_git_diff(&diff_output)
}

pub(crate) fn get_git_root() -> Result<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Failed to get git root: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

pub(crate) fn ensure_git_commit_available(commit_sha: &str) -> Result<()> {
    let object = format!("{commit_sha}^{{commit}}");
    let output = Command::new("git")
        .args(["cat-file", "-e", &object])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let reason = if stderr.is_empty() {
            "unknown error".to_string()
        } else {
            stderr
        };
        return Err(anyhow!(
            "Git commit {commit_sha} is not available locally: {reason}"
        ));
    }

    Ok(())
}

fn get_git_diff(
    diff_target: Option<&str>,
    ignore_whitespace: bool,
    mode: LocalDiffMode,
) -> Result<String> {
    let args = build_git_diff_args(diff_target, ignore_whitespace, mode);
    let output = Command::new("git").args(&args).output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Failed to get git diff (git {}): {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8(output.stdout)?)
}

fn build_git_diff_args(
    diff_target: Option<&str>,
    ignore_whitespace: bool,
    mode: LocalDiffMode,
) -> Vec<String> {
    let mut args = vec!["diff".to_string()];
    if ignore_whitespace {
        args.push("-w".to_string());
    }

    if matches!(mode, LocalDiffMode::CachedOnly) {
        args.push("--cached".to_string());
    }

    if let Some(target) = diff_target {
        args.push(target.to_string());
    }

    args
}

fn parse_local_diff_mode(cached_only: bool, uncached_only: bool) -> Result<LocalDiffMode> {
    if cached_only && uncached_only {
        return Err(anyhow!(
            "Cannot combine --cached-only and --uncached-only for local diff"
        ));
    }

    if cached_only {
        Ok(LocalDiffMode::CachedOnly)
    } else if uncached_only {
        Ok(LocalDiffMode::UncachedOnly)
    } else {
        Ok(LocalDiffMode::All)
    }
}

fn resolve_local_diff_target(
    target: Option<&str>,
    mode: LocalDiffMode,
    merge_base: bool,
) -> Result<Option<String>> {
    if matches!(mode, LocalDiffMode::UncachedOnly) {
        if target.is_some() {
            return Err(anyhow!(
                "Cannot use a revision target with --uncached-only (use --cached-only or default mode)"
            ));
        }
        if merge_base {
            return Err(anyhow!(
                "Cannot use --merge-base with --uncached-only (requires a revision target)"
            ));
        }
        return Ok(None);
    }

    let selected_target = target.unwrap_or("HEAD");
    if merge_base {
        return Ok(Some(get_merge_base(selected_target)?));
    }
    Ok(Some(selected_target.to_string()))
}

fn should_include_untracked(mode: LocalDiffMode, tracked_only: bool) -> bool {
    !tracked_only && !matches!(mode, LocalDiffMode::CachedOnly)
}

fn get_merge_base(target: &str) -> Result<String> {
    let output = Command::new("git")
        .args(["merge-base", "HEAD", target])
        .output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Failed to compute merge-base with {target}: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn get_untracked_review_files(ignore_whitespace: bool) -> Result<Vec<ReviewFile>> {
    let paths = get_untracked_paths()?;
    if paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut files = Vec::new();
    for path in paths {
        let patch = get_untracked_file_patch(&path, ignore_whitespace)?;
        if patch.is_empty() {
            continue;
        }
        files.extend(parse_git_diff(&patch)?);
    }

    Ok(files)
}

fn get_untracked_paths() -> Result<Vec<String>> {
    let output = Command::new("git")
        .args(["ls-files", "--others", "--exclude-standard"])
        .output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Failed to list untracked files: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8(output.stdout)?
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

fn get_untracked_file_patch(path: &str, ignore_whitespace: bool) -> Result<String> {
    let mut args = vec![
        "diff".to_string(),
        "--no-index".to_string(),
        "--".to_string(),
        "/dev/null".to_string(),
        path.to_string(),
    ];

    if ignore_whitespace {
        args.insert(1, "-w".to_string());
    }

    let output = Command::new("git").args(&args).output()?;
    let status = output.status.code().unwrap_or(-1);

    if status != 0 && status != 1 {
        return Err(anyhow!(
            "Failed to get untracked file patch (git {}): {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(String::from_utf8(output.stdout)?)
}

fn build_pr_diff_target(base_sha: &str, head_sha: &str) -> String {
    format!("{base_sha}...{head_sha}")
}

pub(crate) fn parse_git_diff(diff_output: &str) -> Result<Vec<ReviewFile>> {
    let mut files = Vec::new();

    let file_header_re = Regex::new(r"^diff --git a/(.+) b/(.+)$")?;
    let status_re = Regex::new(r"^(new file|deleted file|renamed)")?;
    let additions_re = Regex::new(r"^\+[^+]")?;
    let deletions_re = Regex::new(r"^-[^-]")?;

    let lines: Vec<&str> = diff_output.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        if let Some(caps) = file_header_re.captures(lines[i]) {
            let path = caps[2].to_string();
            i += 1;

            let mut status = FileStatus::Modified;

            // Look for status indicators and find patch start
            while i < lines.len() && !lines[i].starts_with("diff --git") {
                if let Some(status_caps) = status_re.captures(lines[i]) {
                    status = match &status_caps[1] {
                        "new file" => FileStatus::Added,
                        "deleted file" => FileStatus::Deleted,
                        "renamed" => FileStatus::Renamed,
                        _ => FileStatus::Modified,
                    };
                }
                if lines[i].starts_with("@@") {
                    break;
                }
                i += 1;
            }

            // Collect patch content
            let mut patch_lines = Vec::new();
            let mut additions = 0u32;
            let mut deletions = 0u32;

            while i < lines.len() && !lines[i].starts_with("diff --git") {
                let line = lines[i];
                patch_lines.push(line);

                if additions_re.is_match(line) {
                    additions += 1;
                } else if deletions_re.is_match(line) {
                    deletions += 1;
                }

                i += 1;
            }

            let patch = patch_lines.join("\n");
            let change_blocks = parse_patch(&patch);

            // Only include files with actual changes
            if !change_blocks.is_empty() {
                files.push(ReviewFile {
                    path,
                    status,
                    additions,
                    deletions,
                    content: None, // Local diff doesn't need content, files are on disk
                    change_blocks,
                });
            }
        } else {
            i += 1;
        }
    }

    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_git_diff_args_with_ignore_whitespace() {
        let args = build_git_diff_args(Some("HEAD"), true, LocalDiffMode::All);
        assert_eq!(args, vec!["diff", "-w", "HEAD"]);
    }

    #[test]
    fn test_build_git_diff_args_without_ignore_whitespace() {
        let args = build_git_diff_args(Some("HEAD"), false, LocalDiffMode::All);
        assert_eq!(args, vec!["diff", "HEAD"]);
    }

    #[test]
    fn test_build_git_diff_args_cached_mode() {
        let args = build_git_diff_args(Some("main"), true, LocalDiffMode::CachedOnly);
        assert_eq!(args, vec!["diff", "-w", "--cached", "main"]);
    }

    #[test]
    fn test_build_git_diff_args_uncached_mode_has_no_target() {
        let args = build_git_diff_args(None, true, LocalDiffMode::UncachedOnly);
        assert_eq!(args, vec!["diff", "-w"]);
    }

    #[test]
    fn test_parse_local_diff_mode_conflict_errors() {
        let result = parse_local_diff_mode(true, true);
        assert!(result.is_err());
    }

    #[test]
    fn test_resolve_local_diff_target_defaults_to_head() {
        let target = resolve_local_diff_target(None, LocalDiffMode::All, false).unwrap();
        assert_eq!(target, Some("HEAD".to_string()));
    }

    #[test]
    fn test_resolve_local_diff_target_errors_for_uncached_with_target() {
        let result = resolve_local_diff_target(Some("main"), LocalDiffMode::UncachedOnly, false);
        assert!(result.is_err());
    }

    #[test]
    fn test_should_include_untracked_defaults_to_true() {
        assert!(should_include_untracked(LocalDiffMode::All, false));
        assert!(should_include_untracked(LocalDiffMode::UncachedOnly, false));
    }

    #[test]
    fn test_should_include_untracked_false_when_disabled_or_cached_only() {
        assert!(!should_include_untracked(LocalDiffMode::All, true));
        assert!(!should_include_untracked(LocalDiffMode::CachedOnly, false));
    }

    #[test]
    fn test_build_pr_diff_target_uses_three_dot_notation() {
        let target = build_pr_diff_target("base123", "head456");
        assert_eq!(target, "base123...head456");
    }

    #[test]
    fn test_ensure_git_commit_available_errors_for_unknown_commit() {
        let result = ensure_git_commit_available("definitely-not-a-real-commit");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_single_file_diff() {
        let diff = r#"diff --git a/test.lua b/test.lua
index abc123..def456 100644
--- a/test.lua
+++ b/test.lua
@@ -1,3 +1,4 @@
 line1
+added line
 line2
 line3"#;

        let files = parse_git_diff(diff).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "test.lua");
        assert_eq!(files[0].status, FileStatus::Modified);
        assert_eq!(files[0].additions, 1);
        assert_eq!(files[0].deletions, 0);
        assert_eq!(files[0].change_blocks.len(), 1);
    }

    #[test]
    fn test_parse_new_file() {
        let diff = r#"diff --git a/new.lua b/new.lua
new file mode 100644
index 0000000..abc123
--- /dev/null
+++ b/new.lua
@@ -0,0 +1,3 @@
+line1
+line2
+line3"#;

        let files = parse_git_diff(diff).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "new.lua");
        assert_eq!(files[0].status, FileStatus::Added);
        assert_eq!(files[0].additions, 3);
    }

    #[test]
    fn test_parse_deleted_file() {
        let diff = r#"diff --git a/old.lua b/old.lua
deleted file mode 100644
index abc123..0000000
--- a/old.lua
+++ /dev/null
@@ -1,3 +0,0 @@
-line1
-line2
-line3"#;

        let files = parse_git_diff(diff).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "old.lua");
        assert_eq!(files[0].status, FileStatus::Deleted);
        assert_eq!(files[0].deletions, 3);
    }

    #[test]
    fn test_parse_multiple_files() {
        let diff = r#"diff --git a/file1.lua b/file1.lua
index abc..def 100644
--- a/file1.lua
+++ b/file1.lua
@@ -1,2 +1,3 @@
 line1
+added
 line2
diff --git a/file2.rs b/file2.rs
index 123..456 100644
--- a/file2.rs
+++ b/file2.rs
@@ -1,3 +1,2 @@
 line1
-removed
 line3"#;

        let files = parse_git_diff(diff).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].path, "file1.lua");
        assert_eq!(files[1].path, "file2.rs");
    }

    #[test]
    fn test_parse_empty_diff() {
        let files = parse_git_diff("").unwrap();
        assert!(files.is_empty());
    }

    #[test]
    fn test_parse_multiple_change_blocks() {
        let diff = r#"diff --git a/test.lua b/test.lua
index abc..def 100644
--- a/test.lua
+++ b/test.lua
@@ -1,3 +1,4 @@
 line1
+added1
 line2
 line3
@@ -10,3 +11,4 @@
 line10
+added2
 line11
 line12"#;

        let files = parse_git_diff(diff).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].change_blocks.len(), 2);
    }
}
