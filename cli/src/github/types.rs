use serde::{Deserialize, Serialize};

/// Parsed PR URL components
#[derive(Debug, Clone)]
pub struct PrRef {
    pub owner: String,
    pub repo: String,
    pub number: u64,
}

impl PrRef {
    pub fn url(&self) -> String {
        format!(
            "https://github.com/{}/{}/pull/{}",
            self.owner, self.repo, self.number
        )
    }
}

/// Pull request metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub head_sha: String,
    pub base_ref: String,
    pub head_ref: String,
    pub author: String,
    pub state: String,
}

/// A file changed in the PR
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewFile {
    pub path: String,
    pub status: FileStatus,
    pub additions: u32,
    pub deletions: u32,
    /// Full file content at HEAD (None if file was deleted)
    pub content: Option<String>,
    /// Parsed hunks from the diff
    pub hunks: Vec<crate::diff::types::Hunk>,
}

/// File change status
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum FileStatus {
    Added,
    Modified,
    Deleted,
    Renamed,
}

impl From<&str> for FileStatus {
    fn from(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "added" => FileStatus::Added,
            "removed" | "deleted" => FileStatus::Deleted,
            "renamed" => FileStatus::Renamed,
            _ => FileStatus::Modified,
        }
    }
}

/// A review comment on the PR
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewComment {
    pub id: u64,
    pub path: String,
    pub line: Option<u32>,
    pub side: String,
    pub body: String,
    pub author: String,
    pub created_at: String,
    pub html_url: String,
}

/// Response from the fetch command
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FetchResponse {
    pub pr: PullRequest,
    pub files: Vec<ReviewFile>,
    pub comments: Vec<ReviewComment>,
}

/// Response from the comment command
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommentResponse {
    pub success: bool,
    pub comment_id: Option<u64>,
    pub html_url: Option<String>,
    pub error: Option<String>,
}

/// Response from the comments command
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommentsResponse {
    pub comments: Vec<ReviewComment>,
}

#[cfg(test)]
mod tests {
    use super::*;

    mod file_status_from {
        use super::*;

        #[test]
        fn added() {
            assert_eq!(FileStatus::from("added"), FileStatus::Added);
            assert_eq!(FileStatus::from("ADDED"), FileStatus::Added);
            assert_eq!(FileStatus::from("Added"), FileStatus::Added);
        }

        #[test]
        fn deleted() {
            assert_eq!(FileStatus::from("deleted"), FileStatus::Deleted);
            assert_eq!(FileStatus::from("removed"), FileStatus::Deleted);
            assert_eq!(FileStatus::from("REMOVED"), FileStatus::Deleted);
        }

        #[test]
        fn renamed() {
            assert_eq!(FileStatus::from("renamed"), FileStatus::Renamed);
            assert_eq!(FileStatus::from("RENAMED"), FileStatus::Renamed);
        }

        #[test]
        fn modified_explicit() {
            assert_eq!(FileStatus::from("modified"), FileStatus::Modified);
            assert_eq!(FileStatus::from("MODIFIED"), FileStatus::Modified);
        }

        #[test]
        fn modified_fallback() {
            assert_eq!(FileStatus::from("changed"), FileStatus::Modified);
            assert_eq!(FileStatus::from("unknown"), FileStatus::Modified);
            assert_eq!(FileStatus::from(""), FileStatus::Modified);
        }
    }

    mod pr_ref_url {
        use super::*;

        #[test]
        fn formats_correctly() {
            let pr_ref = PrRef {
                owner: "octocat".to_string(),
                repo: "hello-world".to_string(),
                number: 42,
            };
            assert_eq!(
                pr_ref.url(),
                "https://github.com/octocat/hello-world/pull/42"
            );
        }

        #[test]
        fn handles_special_chars_in_names() {
            let pr_ref = PrRef {
                owner: "my-org".to_string(),
                repo: "my_repo.nvim".to_string(),
                number: 1,
            };
            assert_eq!(
                pr_ref.url(),
                "https://github.com/my-org/my_repo.nvim/pull/1"
            );
        }
    }
}
