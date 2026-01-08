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
            let mut has_additions = false;
            let mut has_deletions = false;
            let mut new_line_num = new_start;

            while i < lines.len() {
                let content_line = lines[i];

                if content_line.starts_with("@@") || content_line.starts_with("diff ") {
                    break;
                }

                if content_line.starts_with('-') {
                    old_lines.push(content_line[1..].to_string());
                    deleted_at.push(new_line_num);
                    has_deletions = true;
                } else if content_line.starts_with('+') {
                    added_lines.push(new_line_num);
                    has_additions = true;
                    new_line_num += 1;
                } else if content_line.starts_with(' ') || content_line.is_empty() {
                    new_line_num += 1;
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
                deleted_at,
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
}
