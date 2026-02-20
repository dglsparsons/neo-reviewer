use anyhow::{Result, anyhow};
use octocrab::Octocrab;
use regex::Regex;

use super::auth::get_token;
use super::types::{PrRef, PullRequest, ReviewComment};

/// GitHub API client wrapper
pub struct GitHubClient {
    octocrab: Octocrab,
    token: String,
}

impl GitHubClient {
    /// Create a new authenticated GitHub client
    pub fn new() -> Result<Self> {
        let token = get_token()?;
        let octocrab = Octocrab::builder().personal_token(token.clone()).build()?;
        Ok(Self { octocrab, token })
    }

    /// Parse a GitHub PR URL into its components
    pub fn parse_pr_url(url: &str) -> Result<PrRef> {
        let re = Regex::new(r"github\.com/([^/]+)/([^/]+)/pull/(\d+)")?;
        let caps = re
            .captures(url)
            .ok_or_else(|| anyhow!("Invalid GitHub PR URL: {}", url))?;

        Ok(PrRef {
            owner: caps[1].to_string(),
            repo: caps[2].to_string(),
            number: caps[3].parse()?,
        })
    }

    /// Get the authenticated user's login
    pub async fn get_viewer(&self) -> Result<String> {
        let user = self.octocrab.current().user().await?;
        Ok(user.login)
    }

    /// Fetch PR metadata
    pub async fn get_pr(&self, pr_ref: &PrRef) -> Result<PullRequest> {
        let pr = self
            .octocrab
            .pulls(&pr_ref.owner, &pr_ref.repo)
            .get(pr_ref.number)
            .await?;

        Ok(PullRequest {
            number: pr.number,
            title: pr.title.unwrap_or_default(),
            description: pr.body,
            url: pr_ref.url(),
            base_sha: pr.base.sha,
            head_sha: pr.head.sha,
            base_ref: pr.base.ref_field,
            head_ref: pr.head.ref_field,
            author: pr.user.map(|u| u.login).unwrap_or_default(),
            state: pr
                .state
                .map(|s| format!("{:?}", s).to_lowercase())
                .unwrap_or_else(|| "unknown".to_string()),
        })
    }

    /// Fetch review comments for the PR
    pub async fn get_review_comments(&self, pr_ref: &PrRef) -> Result<Vec<ReviewComment>> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/{}/comments",
            pr_ref.owner, pr_ref.repo, pr_ref.number
        );

        #[derive(serde::Deserialize)]
        struct CommentRaw {
            id: u64,
            path: String,
            line: Option<u32>,
            start_line: Option<u32>,
            side: Option<String>,
            start_side: Option<String>,
            body: String,
            user: Option<UserRaw>,
            created_at: String,
            html_url: String,
            in_reply_to_id: Option<u64>,
        }

        #[derive(serde::Deserialize)]
        struct UserRaw {
            login: String,
        }

        let client = reqwest::Client::new();
        let response = client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Failed to fetch comments: {} - {}",
                status,
                error_body
            ));
        }

        let raw_comments: Vec<CommentRaw> = response.json().await?;

        let review_comments: Vec<ReviewComment> = raw_comments
            .into_iter()
            .map(|c| ReviewComment {
                id: c.id,
                path: c.path,
                line: c.line,
                start_line: c.start_line,
                side: c.side.unwrap_or_default(),
                start_side: c.start_side,
                body: c.body,
                author: c.user.map(|u| u.login).unwrap_or_default(),
                created_at: c.created_at,
                html_url: c.html_url,
                in_reply_to_id: c.in_reply_to_id,
            })
            .collect();

        Ok(review_comments)
    }

    /// Add a review comment to a specific line or line range using raw API
    #[allow(clippy::too_many_arguments)]
    pub async fn add_review_comment(
        &self,
        pr_ref: &PrRef,
        head_sha: &str,
        path: &str,
        line: u32,
        side: &str,
        body: &str,
        start_line: Option<u32>,
        start_side: Option<&str>,
    ) -> Result<ReviewComment> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/{}/comments",
            pr_ref.owner, pr_ref.repo, pr_ref.number
        );

        #[derive(serde::Serialize)]
        struct CommentRequest {
            body: String,
            commit_id: String,
            path: String,
            line: u32,
            side: String,
            #[serde(skip_serializing_if = "Option::is_none")]
            start_line: Option<u32>,
            #[serde(skip_serializing_if = "Option::is_none")]
            start_side: Option<String>,
        }

        #[derive(serde::Deserialize)]
        struct CommentResponseRaw {
            id: u64,
            path: Option<String>,
            line: Option<u32>,
            start_line: Option<u32>,
            side: Option<String>,
            start_side: Option<String>,
            body: Option<String>,
            user: Option<UserRaw>,
            created_at: Option<String>,
            html_url: Option<String>,
        }

        #[derive(serde::Deserialize)]
        struct UserRaw {
            login: String,
        }

        let client = reqwest::Client::new();
        let response = client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .json(&CommentRequest {
                body: body.to_string(),
                commit_id: head_sha.to_string(),
                path: path.to_string(),
                line,
                side: side.to_uppercase(),
                start_line,
                start_side: start_side.map(|s| s.to_uppercase()),
            })
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Failed to create comment: {} - {}",
                status,
                error_body
            ));
        }

        let raw: CommentResponseRaw = response.json().await?;

        Ok(ReviewComment {
            id: raw.id,
            path: raw.path.unwrap_or_default(),
            line: raw.line,
            start_line: raw.start_line,
            side: raw.side.unwrap_or_default(),
            start_side: raw.start_side,
            body: raw.body.unwrap_or_default(),
            author: raw.user.map(|u| u.login).unwrap_or_default(),
            created_at: raw.created_at.unwrap_or_default(),
            html_url: raw.html_url.unwrap_or_default(),
            in_reply_to_id: None,
        })
    }

    pub async fn reply_to_comment(
        &self,
        pr_ref: &PrRef,
        comment_id: u64,
        body: &str,
    ) -> Result<ReviewComment> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/{}/comments/{}/replies",
            pr_ref.owner, pr_ref.repo, pr_ref.number, comment_id
        );

        #[derive(serde::Serialize)]
        struct ReplyRequest {
            body: String,
        }

        #[derive(serde::Deserialize)]
        struct ReplyResponseRaw {
            id: u64,
            path: Option<String>,
            line: Option<u32>,
            side: Option<String>,
            body: Option<String>,
            user: Option<UserRaw>,
            created_at: Option<String>,
            html_url: Option<String>,
            in_reply_to_id: Option<u64>,
        }

        #[derive(serde::Deserialize)]
        struct UserRaw {
            login: String,
        }

        let client = reqwest::Client::new();
        let response = client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .json(&ReplyRequest {
                body: body.to_string(),
            })
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Failed to reply to comment: {} - {}",
                status,
                error_body
            ));
        }

        let raw: ReplyResponseRaw = response.json().await?;

        Ok(ReviewComment {
            id: raw.id,
            path: raw.path.unwrap_or_default(),
            line: raw.line,
            start_line: None,
            side: raw.side.unwrap_or_default(),
            start_side: None,
            body: raw.body.unwrap_or_default(),
            author: raw.user.map(|u| u.login).unwrap_or_default(),
            created_at: raw.created_at.unwrap_or_default(),
            html_url: raw.html_url.unwrap_or_default(),
            in_reply_to_id: raw.in_reply_to_id,
        })
    }

    pub async fn edit_review_comment(
        &self,
        pr_ref: &PrRef,
        comment_id: u64,
        body: &str,
    ) -> Result<ReviewComment> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/comments/{}",
            pr_ref.owner, pr_ref.repo, comment_id
        );

        #[derive(serde::Serialize)]
        struct EditRequest {
            body: String,
        }

        #[derive(serde::Deserialize)]
        struct EditResponseRaw {
            id: u64,
            path: Option<String>,
            line: Option<u32>,
            start_line: Option<u32>,
            side: Option<String>,
            start_side: Option<String>,
            body: Option<String>,
            user: Option<UserRaw>,
            created_at: Option<String>,
            html_url: Option<String>,
            in_reply_to_id: Option<u64>,
        }

        #[derive(serde::Deserialize)]
        struct UserRaw {
            login: String,
        }

        let client = reqwest::Client::new();
        let response = client
            .patch(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .json(&EditRequest {
                body: body.to_string(),
            })
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Failed to edit comment: {} - {}",
                status,
                error_body
            ));
        }

        let raw: EditResponseRaw = response.json().await?;

        Ok(ReviewComment {
            id: raw.id,
            path: raw.path.unwrap_or_default(),
            line: raw.line,
            start_line: raw.start_line,
            side: raw.side.unwrap_or_default(),
            start_side: raw.start_side,
            body: raw.body.unwrap_or_default(),
            author: raw.user.map(|u| u.login).unwrap_or_default(),
            created_at: raw.created_at.unwrap_or_default(),
            html_url: raw.html_url.unwrap_or_default(),
            in_reply_to_id: raw.in_reply_to_id,
        })
    }

    pub async fn delete_review_comment(&self, pr_ref: &PrRef, comment_id: u64) -> Result<()> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/comments/{}",
            pr_ref.owner, pr_ref.repo, comment_id
        );

        let client = reqwest::Client::new();
        let response = client
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Failed to delete comment: {} - {}",
                status,
                error_body
            ));
        }

        Ok(())
    }

    pub async fn submit_review(
        &self,
        pr_ref: &PrRef,
        event: &str,
        body: Option<&str>,
    ) -> Result<()> {
        let url = format!(
            "https://api.github.com/repos/{}/{}/pulls/{}/reviews",
            pr_ref.owner, pr_ref.repo, pr_ref.number
        );

        #[derive(serde::Serialize)]
        struct ReviewRequest {
            event: String,
            #[serde(skip_serializing_if = "Option::is_none")]
            body: Option<String>,
        }

        let client = reqwest::Client::new();
        let response = client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "neo-reviewer")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .json(&ReviewRequest {
                event: event.to_string(),
                body: body.map(|s| s.to_string()),
            })
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let error_body = response.text().await.unwrap_or_default();

            #[derive(serde::Deserialize)]
            struct GitHubError {
                #[serde(default)]
                errors: Vec<String>,
            }

            let friendly_msg = serde_json::from_str::<GitHubError>(&error_body)
                .ok()
                .and_then(|e| e.errors.into_iter().next())
                .unwrap_or_else(|| format!("{} - {}", status, error_body));

            return Err(anyhow!("Failed to submit review: {}", friendly_msg));
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    mod parse_pr_url {
        use super::*;

        #[test]
        fn valid_url() {
            let result = GitHubClient::parse_pr_url("https://github.com/owner/repo/pull/123");
            assert!(result.is_ok());
            let pr_ref = result.unwrap();
            assert_eq!(pr_ref.owner, "owner");
            assert_eq!(pr_ref.repo, "repo");
            assert_eq!(pr_ref.number, 123);
        }

        #[test]
        fn valid_url_with_trailing_slash() {
            let result = GitHubClient::parse_pr_url("https://github.com/owner/repo/pull/123/");
            assert!(result.is_ok());
            let pr_ref = result.unwrap();
            assert_eq!(pr_ref.number, 123);
        }

        #[test]
        fn valid_url_with_query_params() {
            let result =
                GitHubClient::parse_pr_url("https://github.com/owner/repo/pull/456?tab=files");
            assert!(result.is_ok());
            let pr_ref = result.unwrap();
            assert_eq!(pr_ref.number, 456);
        }

        #[test]
        fn valid_url_with_fragment() {
            let result = GitHubClient::parse_pr_url(
                "https://github.com/owner/repo/pull/789#issuecomment-123",
            );
            assert!(result.is_ok());
            let pr_ref = result.unwrap();
            assert_eq!(pr_ref.number, 789);
        }

        #[test]
        fn valid_url_http() {
            let result = GitHubClient::parse_pr_url("http://github.com/owner/repo/pull/42");
            assert!(result.is_ok());
        }

        #[test]
        fn valid_url_with_hyphens_and_underscores() {
            let result = GitHubClient::parse_pr_url("https://github.com/my-org/my_repo/pull/100");
            assert!(result.is_ok());
            let pr_ref = result.unwrap();
            assert_eq!(pr_ref.owner, "my-org");
            assert_eq!(pr_ref.repo, "my_repo");
        }

        #[test]
        fn invalid_url_not_github() {
            let result = GitHubClient::parse_pr_url("https://gitlab.com/owner/repo/pull/123");
            assert!(result.is_err());
        }

        #[test]
        fn invalid_url_not_pr() {
            let result = GitHubClient::parse_pr_url("https://github.com/owner/repo/issues/123");
            assert!(result.is_err());
        }

        #[test]
        fn invalid_url_missing_number() {
            let result = GitHubClient::parse_pr_url("https://github.com/owner/repo/pull/");
            assert!(result.is_err());
        }

        #[test]
        fn invalid_url_non_numeric_pr() {
            let result = GitHubClient::parse_pr_url("https://github.com/owner/repo/pull/abc");
            assert!(result.is_err());
        }

        #[test]
        fn invalid_url_empty() {
            let result = GitHubClient::parse_pr_url("");
            assert!(result.is_err());
        }

        #[test]
        fn invalid_url_random_string() {
            let result = GitHubClient::parse_pr_url("not a url at all");
            assert!(result.is_err());
        }
    }
}
