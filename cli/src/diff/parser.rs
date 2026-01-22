use super::types::{Hunk, HunkType};
use regex::Regex;

/// Parse a unified diff patch into structured hunks
pub fn parse_patch(patch: &str) -> Vec<Hunk> {
    let mut hunks = Vec::new();
    let hunk_header_re = Regex::new(r"^@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@").unwrap();

    let lines: Vec<&str> = patch.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i];

        // Look for hunk header
        if let Some(caps) = hunk_header_re.captures(line) {
            let old_start: u32 = caps[1].parse().unwrap_or(0);
            let old_count: u32 = caps
                .get(2)
                .map(|m| m.as_str().parse().unwrap_or(1))
                .unwrap_or(1);
            let new_start: u32 = caps[3].parse().unwrap_or(0);
            let new_count: u32 = caps
                .get(4)
                .map(|m| m.as_str().parse().unwrap_or(1))
                .unwrap_or(1);

            i += 1;

            let mut old_lines = Vec::new();
            let mut added_lines = Vec::new();
            let mut deleted_at = Vec::new();
            let mut deleted_old_lines = Vec::new();
            let mut changed_lines = Vec::new();
            let mut has_additions = false;
            let mut has_deletions = false;
            let mut new_line_num = new_start;
            let mut old_line_num = old_start;
            // Treat additions immediately following deletions (no context lines) as replacements.
            let mut in_change_block = false;

            while i < lines.len() {
                let content_line = lines[i];

                if content_line.starts_with("@@") || content_line.starts_with("diff ") {
                    break;
                }

                if let Some(stripped) = content_line.strip_prefix('-') {
                    old_lines.push(stripped.to_string());
                    deleted_at.push(new_line_num);
                    deleted_old_lines.push(old_line_num);
                    has_deletions = true;
                    in_change_block = true;
                    old_line_num += 1;
                } else if content_line.strip_prefix('+').is_some() {
                    added_lines.push(new_line_num);
                    if in_change_block {
                        changed_lines.push(new_line_num);
                    }
                    has_additions = true;
                    new_line_num += 1;
                } else if content_line.starts_with(' ') || content_line.is_empty() {
                    in_change_block = false;
                    new_line_num += 1;
                    old_line_num += 1;
                }

                i += 1;
            }

            // Determine hunk type
            let hunk_type = match (has_additions, has_deletions) {
                (true, true) => HunkType::Change,
                (true, false) => HunkType::Add,
                (false, true) => HunkType::Delete,
                (false, false) => continue, // Empty hunk, skip
            };

            hunks.push(Hunk {
                start: new_start,
                count: new_count,
                old_start,
                old_count,
                old_lines,
                hunk_type,
                added_lines,
                changed_lines,
                deleted_at,
                deleted_old_lines,
            });
        } else {
            i += 1;
        }
    }

    hunks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_patch() {
        let patch = r#"@@ -1,3 +1,4 @@
 line1
+added line
 line2
 line3"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].start, 1);
        assert_eq!(hunks[0].count, 4);
        assert_eq!(hunks[0].hunk_type, HunkType::Add);
        assert!(hunks[0].old_lines.is_empty());
    }

    #[test]
    fn test_parse_deletion() {
        let patch = r#"@@ -1,4 +1,3 @@
 line1
-deleted line
 line2
 line3"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].hunk_type, HunkType::Delete);
        assert_eq!(hunks[0].old_lines, vec!["deleted line"]);
    }

    #[test]
    fn test_parse_change() {
        let patch = r#"@@ -1,3 +1,3 @@
 line1
-old line
+new line
 line3"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].hunk_type, HunkType::Change);
        assert_eq!(hunks[0].old_lines, vec!["old line"]);
        assert_eq!(hunks[0].changed_lines, vec![2]);
    }

    #[test]
    fn test_parse_multiple_hunks() {
        let patch = r#"@@ -1,3 +1,4 @@
 line1
+added
 line2
 line3
@@ -10,3 +11,2 @@
 line10
-removed
 line12"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 2);
        assert_eq!(hunks[0].start, 1);
        assert_eq!(hunks[1].start, 11);
    }

    #[test]
    fn test_parse_empty_patch() {
        let hunks = parse_patch("");
        assert!(hunks.is_empty());
    }

    #[test]
    fn test_parse_context_only_skipped() {
        let patch = r#"@@ -1,3 +1,3 @@
 line1
 line2
 line3"#;

        let hunks = parse_patch(patch);
        assert!(hunks.is_empty());
    }

    #[test]
    fn test_parse_no_newline_marker() {
        let patch = r#"@@ -1,2 +1,2 @@
-old line
+new line
\ No newline at end of file"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].hunk_type, HunkType::Change);
    }

    #[test]
    fn test_parse_single_line_hunk() {
        let patch = r#"@@ -1 +1 @@
-old
+new"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_count, 1);
        assert_eq!(hunks[0].count, 1);
    }

    #[test]
    fn test_parse_large_line_numbers() {
        let patch = r#"@@ -10000,3 +10001,4 @@
 context
+added
 more context
 end"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_start, 10000);
        assert_eq!(hunks[0].start, 10001);
    }

    #[test]
    fn test_parse_multiple_additions() {
        let patch = r#"@@ -1,2 +1,5 @@
 line1
+added1
+added2
+added3
 line2"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].hunk_type, HunkType::Add);
        assert_eq!(hunks[0].added_lines.len(), 3);
    }

    #[test]
    fn test_parse_multiple_deletions() {
        let patch = r#"@@ -1,5 +1,2 @@
 line1
-del1
-del2
-del3
 line2"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].hunk_type, HunkType::Delete);
        assert_eq!(hunks[0].old_lines.len(), 3);
    }

    #[test]
    fn test_parse_tracks_added_line_numbers() {
        let patch = r#"@@ -1,3 +1,5 @@
 line1
+added1
 line2
+added2
 line3"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks[0].added_lines, vec![2, 4]);
    }

    #[test]
    fn test_parse_tracks_changed_lines_in_mixed_hunk() {
        let patch = r#"@@ -1,5 +1,6 @@
 line1
-old line
+new line
 line2
+added line
 line3"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].added_lines, vec![2, 4]);
        assert_eq!(hunks[0].changed_lines, vec![2]);
    }

    #[test]
    fn test_parse_tracks_deleted_positions() {
        let patch = r#"@@ -1,4 +1,2 @@
 line1
-deleted1
-deleted2
 line2"#;

        let hunks = parse_patch(patch);
        assert_eq!(hunks[0].deleted_at, vec![2, 2]);
    }
}
