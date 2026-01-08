use anyhow::Result;

use crate::github::client::GitHubClient;

pub async fn run(url: &str, event: &str, body: Option<&str>) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    client.submit_review(&pr_ref, event, body).await?;

    println!(
        "{}",
        serde_json::json!({
            "success": true,
            "event": event,
        })
    );

    Ok(())
}
