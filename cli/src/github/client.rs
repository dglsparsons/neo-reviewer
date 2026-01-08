use anyhow::{Result, anyhow};
use octocrab::Octocrab;
use regex::Regex;

use super::auth::get_token;
use super::types::{FileStatus, PrRef, PullRequest, ReviewComment, ReviewFile};
use crate::diff::parser::parse_patch;

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
            url: pr_ref.url(),
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

    /// Fetch files changed in the PR with their patches
    pub async fn get_pr_files(&self, pr_ref: &PrRef, head_sha: &str) -> Result<Vec<ReviewFile>> {
        let files = self
            .octocrab
            .pulls(&pr_ref.owner, &pr_ref.repo)
            .list_files(pr_ref.number)
            .await?;

        let mut review_files = Vec::new();

        for file in files {
            // Convert DiffEntryStatus to string via Debug format
            let status_str = format!("{:?}", file.status).to_lowercase();
            let status = FileStatus::from(status_str.as_str());

            let hunks = file
                .patch
                .as_ref()
                .map(|p| parse_patch(p))
                .unwrap_or_default();

            // Fetch file content at HEAD (unless deleted)
            let content = if status != FileStatus::Deleted {
                self.get_file_content(pr_ref, &file.filename, head_sha)
                    .await
                    .ok()
            } else {
                None
            };

            review_files.push(ReviewFile {
                path: file.filename,
                status,
                additions: file.additions as u32,
                deletions: file.deletions as u32,
                content,
                hunks,
            });
        }

        Ok(review_files)
    }

    /// Fetch file content at a specific commit
    async fn get_file_content(&self, pr_ref: &PrRef, path: &str, sha: &str) -> Result<String> {
        let content = self
            .octocrab
            .repos(&pr_ref.owner, &pr_ref.repo)
            .get_content()
            .path(path)
            .r#ref(sha)
            .send()
            .await?;

        match content.items.first() {
            Some(item) => {
                if let Some(encoded) = &item.content {
                    // Content is base64 encoded
                    let decoded = base64_decode(encoded)?;
                    Ok(decoded)
                } else {
                    Err(anyhow!("File content is empty"))
                }
            }
            None => Err(anyhow!("File not found: {}", path)),
        }
    }

    /// Fetch review comments for the PR
    pub async fn get_review_comments(&self, pr_ref: &PrRef) -> Result<Vec<ReviewComment>> {
        let comments = self
            .octocrab
            .pulls(&pr_ref.owner, &pr_ref.repo)
            .list_comments(Some(pr_ref.number))
            .send()
            .await?;

        let review_comments: Vec<ReviewComment> = comments
            .items
            .into_iter()
            .map(|c| ReviewComment {
                id: c.id.0,
                path: c.path,
                line: c.line.map(|l| l as u32),
                side: c.side.unwrap_or_default(),
                body: c.body,
                author: c.user.map(|u| u.login).unwrap_or_default(),
                created_at: c.created_at.to_rfc3339(),
                html_url: c.html_url.to_string(),
            })
            .collect();

        Ok(review_comments)
    }

    /// Add a review comment to a specific line using raw API
    pub async fn add_review_comment(
        &self,
        pr_ref: &PrRef,
        head_sha: &str,
        path: &str,
        line: u32,
        side: &str,
        body: &str,
    ) -> Result<ReviewComment> {
        // Use raw API request since octocrab's builder API is complex
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
        }

        #[derive(serde::Deserialize)]
        struct CommentResponseRaw {
            id: u64,
            path: Option<String>,
            line: Option<u32>,
            side: Option<String>,
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
            .header("User-Agent", "greviewer-cli")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .json(&CommentRequest {
                body: body.to_string(),
                commit_id: head_sha.to_string(),
                path: path.to_string(),
                line,
                side: side.to_uppercase(),
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
            side: raw.side.unwrap_or_default(),
            body: raw.body.unwrap_or_default(),
            author: raw.user.map(|u| u.login).unwrap_or_default(),
            created_at: raw.created_at.unwrap_or_default(),
            html_url: raw.html_url.unwrap_or_default(),
        })
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
            .header("User-Agent", "greviewer-cli")
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
            return Err(anyhow!(
                "Failed to submit review: {} - {}",
                status,
                error_body
            ));
        }

        Ok(())
    }
}

fn base64_decode(encoded: &str) -> Result<String> {
    use base64::Engine;
    let cleaned: String = encoded.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = base64::engine::general_purpose::STANDARD.decode(&cleaned)?;
    Ok(String::from_utf8(bytes)?)
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

    mod base64_decode {
        use super::*;

        #[test]
        fn decode_hello() {
            let result = base64_decode("SGVsbG8=").unwrap();
            assert_eq!(result, "Hello");
        }

        #[test]
        fn decode_strips_newlines() {
            let result = base64_decode("SGVs\nbG8=").unwrap();
            assert_eq!(result, "Hello");
        }

        #[test]
        fn decode_multiline_content() {
            let result = base64_decode("SGVsbG8KV29ybGQ=").unwrap();
            assert_eq!(result, "Hello\nWorld");
        }

        #[test]
        fn decode_empty_string() {
            let result = base64_decode("").unwrap();
            assert_eq!(result, "");
        }

        #[test]
        fn decode_no_padding() {
            let result = base64_decode("YWJj").unwrap();
            assert_eq!(result, "abc");
        }

        #[test]
        fn decode_single_padding() {
            let result = base64_decode("YWI=").unwrap();
            assert_eq!(result, "ab");
        }

        #[test]
        fn decode_double_padding() {
            let result = base64_decode("YQ==").unwrap();
            assert_eq!(result, "a");
        }

        #[test]
        fn decode_with_plus_and_slash() {
            let result = base64_decode("Pj4/").unwrap();
            assert_eq!(result, ">>?");
        }

        #[test]
        fn invalid_base64_char() {
            let result = base64_decode("Invalid!Char");
            assert!(result.is_err());
        }

        #[test]
        fn decode_strips_all_whitespace() {
            let result = base64_decode("  SGVs\t\nbG8=  ").unwrap();
            assert_eq!(result, "Hello");
        }
    }
}
