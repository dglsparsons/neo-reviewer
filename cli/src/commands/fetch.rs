use anyhow::Result;

use crate::commands::diff::{ensure_git_commit_available, get_pr_review_files};
use crate::github::client::GitHubClient;
use crate::github::types::FetchResponse;

pub async fn run(url: &str) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    // Fetch PR metadata and viewer in parallel
    let (pr, viewer) = tokio::try_join!(client.get_pr(&pr_ref), client.get_viewer())?;

    ensure_git_commit_available(&pr.base_sha).map_err(|err| {
        anyhow::anyhow!(
            "Missing PR base commit {} locally (base branch '{}'). Run `git fetch origin {}` and retry. {}",
            pr.base_sha,
            pr.base_ref,
            pr.base_ref,
            err
        )
    })?;

    ensure_git_commit_available(&pr.head_sha).map_err(|err| {
        anyhow::anyhow!(
            "Missing PR head commit {} locally. Run `gh pr checkout {}` and retry. {}",
            pr.head_sha,
            pr.number,
            err
        )
    })?;

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
