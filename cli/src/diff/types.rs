use serde::{Deserialize, Serialize};

/// A change block represents a contiguous block of changes without context lines.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeBlock {
    /// Line number in the new file where this block starts (1-indexed)
    pub start_line: u32,
    /// Line number in the new file where this block ends (1-indexed)
    pub end_line: u32,
    /// Type of change in this block
    pub kind: ChangeKind,
    /// Actual line numbers in new file that were added (including replacements) (1-indexed)
    pub added_lines: Vec<u32>,
    /// Line numbers in new file that replace deletions (subset of added_lines)
    pub changed_lines: Vec<u32>,
    /// Grouped deletions with anchors for rendering virtual lines
    pub deletion_groups: Vec<DeletionGroup>,
    /// Mapping from old line numbers to new anchor lines (for LEFT-side comments)
    pub old_to_new: Vec<OldToNewMap>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeletionGroup {
    /// Line number in the new file where the deletion should be anchored (1-indexed)
    pub anchor_line: u32,
    /// Deleted content lines
    pub old_lines: Vec<String>,
    /// Old file line numbers corresponding to old_lines
    pub old_line_numbers: Vec<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OldToNewMap {
    pub old_line: u32,
    pub new_line: u32,
}

/// Type of change in a change block
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ChangeKind {
    /// Lines only in new version (additions)
    Add,
    /// Lines only in old version (deletions)
    Delete,
    /// Lines modified (both additions and deletions)
    Change,
}
