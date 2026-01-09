terraform {
  required_version = ">= 1.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {
  owner = "dglsparsons"
}

resource "github_repository" "greviewer" {
  name        = "greviewer"
  description = "A Neovim plugin for reviewing GitHub pull requests directly in your editor"

  visibility = "public"

  has_issues      = true
  has_discussions = false
  has_projects    = false
  has_wiki        = false
  has_downloads   = false

  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  allow_auto_merge       = true
  delete_branch_on_merge = true

  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "PR_BODY"

  vulnerability_alerts = true

  topics = [
    "neovim",
    "neovim-plugin",
    "github",
    "pull-requests",
    "code-review",
    "lua",
    "rust",
  ]
}

resource "github_branch_protection" "main" {
  repository_id = github_repository.greviewer.node_id
  pattern       = "main"

  required_pull_request_reviews {
    required_approving_review_count = 0
  }

  required_status_checks {
    strict = true
    contexts = [
      "Lua Tests (stable)",
      "Lua Tests (nightly)",
      "Rust (ubuntu-latest)",
      "Rust (macos-latest)",
      "Terraform",
    ]
  }

  required_linear_history = true
  allows_force_pushes     = false
  allows_deletions        = false
  enforce_admins          = false
}

resource "github_actions_repository_permissions" "greviewer" {
  repository = github_repository.greviewer.name

  enabled         = true
  allowed_actions = "selected"

  allowed_actions_config {
    github_owned_allowed = true
    patterns_allowed = [
      "rhysd/action-setup-vim@*",
      "DeterminateSystems/*",
      "dtolnay/rust-toolchain@*",
      "hashicorp/setup-terraform@*",
    ]
  }
}
