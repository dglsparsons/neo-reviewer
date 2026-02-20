use anyhow::Result;

use crate::github::client::GitHubClient;
use crate::github::types::CommentResponse;

pub async fn run(
    url: &str,
    path: &str,
    line: u32,
    side: &str,
    body: &str,
    start_line: Option<u32>,
    start_side: Option<&str>,
) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    let pr = client.get_pr(&pr_ref).await?;

    match client
        .add_review_comment(
            &pr_ref,
            &pr.head_sha,
            path,
            line,
            side,
            body,
            start_line,
            start_side,
        )
        .await
    {
        Ok(comment) => {
            let response = CommentResponse {
                success: true,
                comment_id: Some(comment.id),
                html_url: Some(comment.html_url),
                error: None,
            };
            println!("{}", serde_json::to_string(&response)?);
        }
        Err(e) => {
            let response = CommentResponse {
                success: false,
                comment_id: None,
                html_url: None,
                error: Some(e.to_string()),
            };
            println!("{}", serde_json::to_string(&response)?);
        }
    }

    Ok(())
}

pub async fn run_edit(url: &str, comment_id: u64, body: &str) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    match client.edit_review_comment(&pr_ref, comment_id, body).await {
        Ok(comment) => {
            let response = CommentResponse {
                success: true,
                comment_id: Some(comment.id),
                html_url: Some(comment.html_url),
                error: None,
            };
            println!("{}", serde_json::to_string(&response)?);
        }
        Err(e) => {
            let response = CommentResponse {
                success: false,
                comment_id: None,
                html_url: None,
                error: Some(e.to_string()),
            };
            println!("{}", serde_json::to_string(&response)?);
        }
    }

    Ok(())
}

pub async fn run_delete(url: &str, comment_id: u64) -> Result<()> {
    let client = GitHubClient::new()?;
    let pr_ref = GitHubClient::parse_pr_url(url)?;

    match client.delete_review_comment(&pr_ref, comment_id).await {
        Ok(()) => {
            let response = CommentResponse {
                success: true,
                comment_id: Some(comment_id),
                html_url: None,
                error: None,
            };
            println!("{}", serde_json::to_string(&response)?);
        }
        Err(e) => {
            let response = CommentResponse {
                success: false,
                comment_id: None,
                html_url: None,
                error: Some(e.to_string()),
            };
            println!("{}", serde_json::to_string(&response)?);
        }
    }

    Ok(())
}
