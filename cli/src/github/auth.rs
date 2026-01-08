use anyhow::{Result, anyhow};
use std::process::Command;

/// Get GitHub token, prioritizing `gh auth token` for SSO compatibility
#[allow(clippy::collapsible_if)]
pub fn get_token() -> Result<String> {
    if let Ok(output) = Command::new("gh").args(["auth", "token"]).output() {
        if output.status.success() {
            let token = String::from_utf8(output.stdout)?.trim().to_string();
            if !token.is_empty() {
                return Ok(token);
            }
        }
    }

    // Fall back to GITHUB_TOKEN environment variable
    std::env::var("GITHUB_TOKEN").map_err(|_| {
        anyhow!(
            "No GitHub token found.\n\
             Either run `gh auth login` or set the GITHUB_TOKEN environment variable."
        )
    })
}

/// Check if authentication is available and valid
pub async fn check_auth() -> Result<AuthStatus> {
    match get_token() {
        Ok(token) => {
            // Verify token works by making a simple API call
            let octocrab = octocrab::Octocrab::builder()
                .personal_token(token)
                .build()?;

            match octocrab.current().user().await {
                Ok(user) => Ok(AuthStatus::Authenticated {
                    username: user.login,
                    source: if std::env::var("GITHUB_TOKEN").is_ok() {
                        "GITHUB_TOKEN".to_string()
                    } else {
                        "gh auth token".to_string()
                    },
                }),
                Err(e) => Ok(AuthStatus::InvalidToken {
                    error: e.to_string(),
                }),
            }
        }
        Err(e) => Ok(AuthStatus::NoToken {
            error: e.to_string(),
        }),
    }
}

#[derive(Debug)]
pub enum AuthStatus {
    Authenticated { username: String, source: String },
    InvalidToken { error: String },
    NoToken { error: String },
}

impl std::fmt::Display for AuthStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthStatus::Authenticated { username, source } => {
                write!(f, "Authenticated as {} (via {})", username, source)
            }
            AuthStatus::InvalidToken { error } => {
                write!(f, "Invalid token: {}", error)
            }
            AuthStatus::NoToken { error } => {
                write!(f, "No token: {}", error)
            }
        }
    }
}
