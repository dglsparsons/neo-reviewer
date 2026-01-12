use anyhow::Result;

use crate::github::client::GitHubClient;
use crate::github::types::FetchResponse;

pub async fn run(url: &str) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    // Fetch PR metadata and viewer in parallel
    let (pr, viewer) = tokio::try_join!(client.get_pr(&pr_ref), client.get_viewer())?;

    // Fetch files with hunks
    let files = client.get_pr_files(&pr_ref, &pr.head_sha).await?;

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
