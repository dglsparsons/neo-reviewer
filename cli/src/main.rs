mod commands;
mod diff;
mod github;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "neo-reviewer")]
#[command(about = "CLI tool for reviewing GitHub pull requests in Neovim")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Parse local git diff for review
    Diff {
        /// Optional revision target (commit/branch/tag), defaults to HEAD
        target: Option<String>,

        /// Only include staged changes
        #[arg(long, conflicts_with = "uncached_only")]
        cached_only: bool,

        /// Only include unstaged changes (cannot be combined with a target)
        #[arg(long, conflicts_with = "cached_only", conflicts_with = "target")]
        uncached_only: bool,

        /// Diff against merge-base(HEAD, target) instead of target directly
        #[arg(long, requires = "target")]
        merge_base: bool,

        /// Exclude untracked files from local diff reviews
        #[arg(long)]
        tracked_only: bool,
    },

    /// Fetch PR data including files, change blocks, and content
    Fetch {
        /// GitHub PR URL (e.g., https://github.com/owner/repo/pull/123)
        #[arg(short, long)]
        url: String,
    },

    /// Add a review comment to a PR
    Comment {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,

        /// File path to comment on
        #[arg(short, long)]
        path: String,

        /// Line number to comment on (end line for multi-line comments)
        #[arg(short, long)]
        line: u32,

        /// Side of the diff (LEFT or RIGHT)
        #[arg(short, long, default_value = "RIGHT")]
        side: String,

        /// Comment body
        #[arg(short, long)]
        body: String,

        /// Start line for multi-line comments
        #[arg(long)]
        start_line: Option<u32>,

        /// Start side for multi-line comments (LEFT or RIGHT)
        #[arg(long)]
        start_side: Option<String>,
    },

    /// Fetch existing review comments for a PR
    Comments {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,
    },

    /// Reply to an existing comment
    Reply {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,

        /// ID of the comment to reply to
        #[arg(short, long)]
        comment_id: u64,

        /// Reply body
        #[arg(short, long)]
        body: String,
    },

    /// Edit an existing review comment
    EditComment {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,

        /// ID of the comment to edit
        #[arg(short, long)]
        comment_id: u64,

        /// Updated comment body
        #[arg(short, long)]
        body: String,
    },

    /// Delete an existing review comment
    DeleteComment {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,

        /// ID of the comment to delete
        #[arg(short, long)]
        comment_id: u64,
    },

    /// Submit a review (approve or request changes)
    Submit {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,

        /// Review event: APPROVE or REQUEST_CHANGES
        #[arg(short, long)]
        event: String,

        /// Optional review body/message
        #[arg(short, long)]
        body: Option<String>,
    },

    /// Check authentication status
    Auth,
}

#[tokio::main]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install rustls crypto provider");

    let cli = Cli::parse();

    match cli.command {
        Commands::Diff {
            target,
            cached_only,
            uncached_only,
            merge_base,
            tracked_only,
        } => {
            commands::diff::run(commands::diff::LocalDiffCliOpts {
                target,
                cached_only,
                uncached_only,
                merge_base,
                tracked_only,
            })?;
        }
        Commands::Fetch { url } => {
            commands::fetch::run(&url).await?;
        }
        Commands::Comment {
            url,
            path,
            line,
            side,
            body,
            start_line,
            start_side,
        } => {
            commands::comment::run(
                &url,
                &path,
                line,
                &side,
                &body,
                start_line,
                start_side.as_deref(),
            )
            .await?;
        }
        Commands::Comments { url } => {
            commands::comments::run(&url).await?;
        }
        Commands::Reply {
            url,
            comment_id,
            body,
        } => {
            commands::reply::run(&url, comment_id, &body).await?;
        }
        Commands::EditComment {
            url,
            comment_id,
            body,
        } => {
            commands::comment::run_edit(&url, comment_id, &body).await?;
        }
        Commands::DeleteComment { url, comment_id } => {
            commands::comment::run_delete(&url, comment_id).await?;
        }
        Commands::Submit { url, event, body } => {
            commands::submit::run(&url, &event, body.as_deref()).await?;
        }
        Commands::Auth => {
            commands::auth::run().await?;
        }
    }

    Ok(())
}
