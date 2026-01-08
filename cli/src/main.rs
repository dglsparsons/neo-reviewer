mod commands;
mod diff;
mod github;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "greviewer-cli")]
#[command(about = "CLI tool for reviewing GitHub pull requests in Neovim")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Fetch PR data including files, hunks, and content
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

        /// Line number to comment on
        #[arg(short, long)]
        line: u32,

        /// Side of the diff (LEFT or RIGHT)
        #[arg(short, long, default_value = "RIGHT")]
        side: String,

        /// Comment body
        #[arg(short, long)]
        body: String,
    },

    /// Fetch existing review comments for a PR
    Comments {
        /// GitHub PR URL
        #[arg(short, long)]
        url: String,
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
    let cli = Cli::parse();

    match cli.command {
        Commands::Fetch { url } => {
            commands::fetch::run(&url).await?;
        }
        Commands::Comment {
            url,
            path,
            line,
            side,
            body,
        } => {
            commands::comment::run(&url, &path, line, &side, &body).await?;
        }
        Commands::Comments { url } => {
            commands::comments::run(&url).await?;
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
