use std::process::Command;

fn cli_path() -> &'static str {
    env!("CARGO_BIN_EXE_neo-reviewer")
}

mod tls {
    use super::*;

    #[test]
    fn https_request_succeeds() {
        let cli = cli_path();

        let output = Command::new(cli)
            .args([
                "fetch",
                "https://github.com/dglsparsons/neo-reviewer/pull/1",
            ])
            .output()
            .expect("Failed to execute CLI");

        let stderr = String::from_utf8_lossy(&output.stderr);

        assert!(
            !stderr.contains("CryptoProvider"),
            "TLS crypto provider not configured: {stderr}"
        );
        assert!(!stderr.contains("panicked"), "CLI panicked: {stderr}");
    }
}

mod fetch {
    use super::*;

    #[test]
    fn invalid_url_returns_error() {
        let cli = cli_path();

        let output = Command::new(cli)
            .args(["fetch", "not-a-url"])
            .output()
            .expect("Failed to execute CLI");

        assert!(!output.status.success());
    }

    #[test]
    fn non_github_url_returns_error() {
        let cli = cli_path();

        let output = Command::new(cli)
            .args(["fetch", "https://gitlab.com/owner/repo/pull/1"])
            .output()
            .expect("Failed to execute CLI");

        assert!(!output.status.success());
    }
}

mod auth {
    use super::*;

    #[test]
    fn auth_check_does_not_panic() {
        let cli = cli_path();

        let output = Command::new(cli)
            .args(["auth", "check"])
            .output()
            .expect("Failed to execute CLI");

        let stderr = String::from_utf8_lossy(&output.stderr);

        assert!(!stderr.contains("panicked"), "CLI panicked: {stderr}");
    }
}
