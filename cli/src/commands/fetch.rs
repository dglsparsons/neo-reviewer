use anyhow::Result;
use regex::Regex;
use std::process::Command;

use crate::commands::diff::{ensure_git_commit_available, get_pr_review_files};
use crate::github::client::GitHubClient;
use crate::github::types::{FetchResponse, PrRef};

pub async fn run(url: &str) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    // Fetch PR metadata and viewer in parallel
    let (pr, viewer) = tokio::try_join!(client.get_pr(&pr_ref), client.get_viewer())?;
    let remote = detect_repo_remote(&pr_ref)?.unwrap_or_else(|| "origin".to_string());

    ensure_base_commit_available(&pr_ref, &remote, &pr.base_sha, &pr.base_ref)?;
    ensure_head_commit_available(&pr_ref, &remote, pr.number, &pr.head_sha, &pr.head_ref)?;

    // Fetch change blocks from local git using the PR commit range.
    let files = get_pr_review_files(&pr.base_sha, &pr.head_sha, true)?;

    // Fetch existing comments
    let comments = client.get_review_comments(&pr_ref).await?;

    let response = FetchResponse {
        pr,
        files,
        comments,
        viewer,
    };

    // Output as JSON for Neovim consumption
    println!("{}", serde_json::to_string(&response)?);

    Ok(())
}

fn ensure_base_commit_available(
    pr_ref: &PrRef,
    remote: &str,
    base_sha: &str,
    base_ref: &str,
) -> Result<()> {
    if ensure_git_commit_available(base_sha).is_ok() {
        return Ok(());
    }

    fetch_remote_ref(remote, base_ref)?;
    if ensure_git_commit_available(base_sha).is_ok() {
        return Ok(());
    }

    Err(anyhow::anyhow!(
        "Missing PR base commit {} locally after fetching {} from remote '{}' for {}/{}. \
Run `git fetch {} {}` and retry.",
        base_sha,
        base_ref,
        remote,
        pr_ref.owner,
        pr_ref.repo,
        remote,
        base_ref
    ))
}

fn ensure_head_commit_available(
    pr_ref: &PrRef,
    remote: &str,
    pr_number: u64,
    head_sha: &str,
    head_ref: &str,
) -> Result<()> {
    if ensure_git_commit_available(head_sha).is_ok() {
        return Ok(());
    }

    // Try branch ref first, then GitHub's pull/<n>/head ref for forked PRs.
    let _ = fetch_remote_ref(remote, head_ref);
    let pull_ref = format!("pull/{pr_number}/head");
    let _ = fetch_remote_ref(remote, &pull_ref);

    if ensure_git_commit_available(head_sha).is_ok() {
        return Ok(());
    }

    Err(anyhow::anyhow!(
        "Missing PR head commit {} locally after fetching '{}' and '{}' from remote '{}' for {}/{}. \
Run `gh pr checkout {}` and retry.",
        head_sha,
        head_ref,
        pull_ref,
        remote,
        pr_ref.owner,
        pr_ref.repo,
        pr_number
    ))
}

fn fetch_remote_ref(remote: &str, git_ref: &str) -> Result<()> {
    let output = Command::new("git")
        .args(["fetch", "--no-tags", remote, git_ref])
        .output()?;

    if !output.status.success() {
        return Err(anyhow::anyhow!(
            "git fetch --no-tags {} {} failed: {}",
            remote,
            git_ref,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    Ok(())
}

fn detect_repo_remote(pr_ref: &PrRef) -> Result<Option<String>> {
    let output = Command::new("git").args(["remote", "-v"]).output()?;
    if !output.status.success() {
        return Ok(None);
    }

    let lines = String::from_utf8(output.stdout)?;
    let remote_line_re = Regex::new(r"^(\S+)\s+(\S+)\s+\(fetch\)$")?;

    for line in lines.lines() {
        if let Some(caps) = remote_line_re.captures(line) {
            let remote_name = caps[1].to_string();
            let remote_url = caps[2].to_string();
            if remote_points_to_repo(&remote_url, &pr_ref.owner, &pr_ref.repo) {
                return Ok(Some(remote_name));
            }
        }
    }

    Ok(None)
}

fn remote_points_to_repo(remote_url: &str, owner: &str, repo: &str) -> bool {
    let ssh_re = Regex::new(r"^git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$").ok();
    let https_re = Regex::new(r"^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?$").ok();

    let mut parsed = None;
    if let Some(re) = ssh_re
        && let Some(caps) = re.captures(remote_url)
    {
        parsed = Some((caps[1].to_string(), caps[2].to_string()));
    }
    if parsed.is_none()
        && let Some(re) = https_re
        && let Some(caps) = re.captures(remote_url)
    {
        parsed = Some((caps[1].to_string(), caps[2].to_string()));
    }

    match parsed {
        Some((remote_owner, remote_repo)) => remote_owner == owner && remote_repo == repo,
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_points_to_repo_matches_https_url() {
        assert!(remote_points_to_repo(
            "https://github.com/owner/repo.git",
            "owner",
            "repo"
        ));
    }

    #[test]
    fn remote_points_to_repo_matches_ssh_url() {
        assert!(remote_points_to_repo(
            "git@github.com:owner/repo.git",
            "owner",
            "repo"
        ));
    }

    #[test]
    fn remote_points_to_repo_rejects_non_matching_repo() {
        assert!(!remote_points_to_repo(
            "https://github.com/owner/other.git",
            "owner",
            "repo"
        ));
    }

    #[test]
    fn remote_points_to_repo_rejects_non_github_url() {
        assert!(!remote_points_to_repo(
            "https://gitlab.com/owner/repo.git",
            "owner",
            "repo"
        ));
    }
}
