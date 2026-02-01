use super::types::{ChangeBlock, ChangeKind, DeletionGroup, OldToNewMap};
use regex::Regex;

#[derive(Default)]
struct BlockBuilder {
    start_line: u32,
    end_line: u32,
    added_lines: Vec<u32>,
    changed_lines: Vec<u32>,
    deletion_groups: Vec<DeletionGroup>,
    old_to_new: Vec<OldToNewMap>,
    has_additions: bool,
    has_deletions: bool,
    initialized: bool,
}

impl BlockBuilder {
    fn ensure_initialized(&mut self, line: u32) {
        if !self.initialized {
            self.start_line = line;
            self.end_line = line;
            self.initialized = true;
        } else {
            self.end_line = line;
        }
    }

    fn push_deletion(&mut self, anchor_line: u32, old_line: String, old_line_number: u32) {
        match self.deletion_groups.last_mut() {
            Some(group) if group.anchor_line == anchor_line => {
                group.old_lines.push(old_line);
                group.old_line_numbers.push(old_line_number);
            }
            _ => self.deletion_groups.push(DeletionGroup {
                anchor_line,
                old_lines: vec![old_line],
                old_line_numbers: vec![old_line_number],
            }),
        }
    }

    fn into_change_block(self) -> Option<ChangeBlock> {
        if !self.initialized || (!self.has_additions && !self.has_deletions) {
            return None;
        }

        let kind = match (self.has_additions, self.has_deletions) {
            (true, true) => ChangeKind::Change,
            (true, false) => ChangeKind::Add,
            (false, true) => ChangeKind::Delete,
            (false, false) => return None,
        };

        Some(ChangeBlock {
            start_line: self.start_line,
            end_line: self.end_line,
            kind,
            added_lines: self.added_lines,
            changed_lines: self.changed_lines,
            deletion_groups: self.deletion_groups,
            old_to_new: self.old_to_new,
        })
    }
}

/// Parse a unified diff patch into contiguous change blocks (no context lines)
pub fn parse_patch(patch: &str) -> Vec<ChangeBlock> {
    let mut blocks = Vec::new();
    let hunk_header_re = Regex::new(r"^@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@").unwrap();

    let lines: Vec<&str> = patch.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i];

        if let Some(caps) = hunk_header_re.captures(line) {
            let old_start: u32 = caps[1].parse().unwrap_or(0);
            let new_start: u32 = caps[3].parse().unwrap_or(0);

            i += 1;

            let mut new_line_num = new_start;
            let mut old_line_num = old_start;
            let mut builder = BlockBuilder::default();
            let mut in_change_block = false;

            while i < lines.len() {
                let content_line = lines[i];

                if content_line.starts_with("@@") || content_line.starts_with("diff ") {
                    break;
                }

                if content_line.starts_with("\\ No newline") {
                    i += 1;
                    continue;
                }

                if let Some(stripped) = content_line.strip_prefix('-') {
                    builder.ensure_initialized(new_line_num);
                    builder.has_deletions = true;
                    builder.push_deletion(new_line_num, stripped.to_string(), old_line_num);
                    builder.old_to_new.push(OldToNewMap {
                        old_line: old_line_num,
                        new_line: new_line_num,
                    });
                    in_change_block = true;
                    old_line_num += 1;
                } else if content_line.strip_prefix('+').is_some() {
                    builder.ensure_initialized(new_line_num);
                    builder.has_additions = true;
                    builder.added_lines.push(new_line_num);
                    if in_change_block {
                        builder.changed_lines.push(new_line_num);
                    }
                    new_line_num += 1;
                } else if content_line.starts_with(' ') || content_line.is_empty() {
                    if let Some(block) = builder.into_change_block() {
                        blocks.push(block);
                    }
                    builder = BlockBuilder::default();
                    in_change_block = false;
                    new_line_num += 1;
                    old_line_num += 1;
                }

                i += 1;
            }

            if let Some(block) = builder.into_change_block() {
                blocks.push(block);
            }
        } else {
            i += 1;
        }
    }

    blocks
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

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Add);
        assert_eq!(blocks[0].start_line, 2);
        assert_eq!(blocks[0].end_line, 2);
        assert_eq!(blocks[0].added_lines, vec![2]);
    }

    #[test]
    fn test_parse_deletion() {
        let patch = r#"@@ -1,4 +1,3 @@
 line1
-deleted line
 line2
 line3"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Delete);
        assert_eq!(blocks[0].start_line, 2);
        assert_eq!(blocks[0].end_line, 2);
        assert_eq!(blocks[0].deletion_groups.len(), 1);
        assert_eq!(blocks[0].deletion_groups[0].anchor_line, 2);
        assert_eq!(blocks[0].deletion_groups[0].old_lines, vec!["deleted line"]);
    }

    #[test]
    fn test_parse_change() {
        let patch = r#"@@ -1,3 +1,3 @@
 line1
-old line
+new line
 line3"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Change);
        assert_eq!(blocks[0].start_line, 2);
        assert_eq!(blocks[0].end_line, 2);
        assert_eq!(blocks[0].added_lines, vec![2]);
        assert_eq!(blocks[0].changed_lines, vec![2]);
        assert_eq!(blocks[0].deletion_groups[0].anchor_line, 2);
        assert_eq!(blocks[0].old_to_new[0].old_line, 2);
        assert_eq!(blocks[0].old_to_new[0].new_line, 2);
    }

    #[test]
    fn test_parse_multiple_blocks() {
        let patch = r#"@@ -1,3 +1,4 @@
 line1
+added
 line2
 line3
@@ -10,3 +11,2 @@
 line10
-removed
 line12"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].start_line, 2);
        assert_eq!(blocks[1].start_line, 12);
    }

    #[test]
    fn test_parse_empty_patch() {
        let blocks = parse_patch("");
        assert!(blocks.is_empty());
    }

    #[test]
    fn test_parse_context_only_skipped() {
        let patch = r#"@@ -1,3 +1,3 @@
 line1
 line2
 line3"#;

        let blocks = parse_patch(patch);
        assert!(blocks.is_empty());
    }

    #[test]
    fn test_parse_no_newline_marker() {
        let patch = r#"@@ -1,2 +1,2 @@
-old line
+new line
\ No newline at end of file"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Change);
    }

    #[test]
    fn test_parse_single_line_block() {
        let patch = r#"@@ -1 +1 @@
-old
+new"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].start_line, 1);
        assert_eq!(blocks[0].end_line, 1);
    }

    #[test]
    fn test_parse_large_line_numbers() {
        let patch = r#"@@ -10000,3 +10001,4 @@
 context
+added
 more context
 end"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].start_line, 10002);
    }

    #[test]
    fn test_parse_multiple_additions() {
        let patch = r#"@@ -1,2 +1,5 @@
 line1
+added1
+added2
+added3
 line2"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Add);
        assert_eq!(blocks[0].added_lines.len(), 3);
        assert_eq!(blocks[0].start_line, 2);
        assert_eq!(blocks[0].end_line, 4);
    }

    #[test]
    fn test_parse_multiple_deletions() {
        let patch = r#"@@ -1,5 +1,2 @@
 line1
-del1
-del2
-del3
 line2"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].kind, ChangeKind::Delete);
        assert_eq!(blocks[0].deletion_groups.len(), 1);
        assert_eq!(blocks[0].deletion_groups[0].old_lines.len(), 3);
    }

    #[test]
    fn test_parse_tracks_added_line_numbers() {
        let patch = r#"@@ -1,3 +1,5 @@
 line1
+added1
 line2
+added2
 line3"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].added_lines, vec![2]);
        assert_eq!(blocks[1].added_lines, vec![4]);
    }

    #[test]
    fn test_parse_tracks_changed_lines_in_mixed_block() {
        let patch = r#"@@ -1,5 +1,6 @@
 line1
-old line
+new line
 line2
+added line
 line3"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].kind, ChangeKind::Change);
        assert_eq!(blocks[0].changed_lines, vec![2]);
        assert_eq!(blocks[1].kind, ChangeKind::Add);
        assert_eq!(blocks[1].added_lines, vec![4]);
    }

    #[test]
    fn test_parse_tracks_deleted_positions() {
        let patch = r#"@@ -1,4 +1,2 @@
 line1
-deleted1
-deleted2
 line2"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].deletion_groups[0].anchor_line, 2);
        assert_eq!(blocks[0].deletion_groups[0].old_lines.len(), 2);
        assert_eq!(blocks[0].old_to_new.len(), 2);
    }

    #[test]
    fn test_parse_splits_deletions_by_anchor() {
        let patch = r#"@@ -1,4 +1,4 @@
 line1
-old1
+new1
-old2
 line2"#;

        let blocks = parse_patch(patch);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].deletion_groups.len(), 2);
        assert_eq!(blocks[0].deletion_groups[0].anchor_line, 2);
        assert_eq!(blocks[0].deletion_groups[1].anchor_line, 3);
    }
}
