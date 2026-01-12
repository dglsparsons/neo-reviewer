---@alias GReviewerHunkType "add"|"delete"|"change"

---@class GReviewerHunk
---@field start? integer Start line of the hunk in the new file
---@field count? integer Number of lines in the hunk
---@field hunk_type GReviewerHunkType Type of change
---@field added_lines? integer[] Line numbers of additions
---@field deleted_at? integer[] Positions where deletions occurred
---@field old_lines string[] Content of deleted lines
---@field deleted_old_lines? integer[] Original line numbers of deleted lines

---@alias GReviewerFileStatus "added"|"deleted"|"modified"|"renamed"

---@class GReviewerFile
---@field path string Relative file path
---@field status GReviewerFileStatus Status of the file
---@field additions? integer Number of additions
---@field deletions? integer Number of deletions
---@field hunks GReviewerHunk[] Hunks in this file

---@class GReviewerPR
---@field number integer PR number
---@field title string PR title

---@alias GReviewerCommentSide "LEFT"|"RIGHT"

---@class GReviewerComment
---@field id integer Comment ID
---@field path string File path the comment is on
---@field line integer Line number
---@field start_line? integer Start line for multi-line comments
---@field side GReviewerCommentSide Which side of the diff
---@field start_side? GReviewerCommentSide Start side for multi-line comments
---@field body string Comment body text
---@field author string Author username
---@field created_at string ISO date string
---@field html_url? string URL to the comment on GitHub
---@field in_reply_to_id? integer ID of parent comment if this is a reply

---@alias GReviewerReviewType "pr"|"local"

---@class GReviewerReview
---@field review_type GReviewerReviewType Type of review session
---@field pr? GReviewerPR PR metadata (for PR reviews)
---@field url? string PR URL (for PR reviews)
---@field git_root? string Git root directory (for local reviews)
---@field files GReviewerFile[] Changed files
---@field files_by_path table<string, GReviewerFile> Files indexed by path
---@field comments GReviewerComment[] Comments on the PR
---@field current_file_idx integer Current file index
---@field expanded_hunks table<string, integer[]> Map of file:hunk to extmark IDs
---@field did_checkout? boolean Whether we checked out a branch
---@field prev_branch? string Previous branch name
---@field did_stash? boolean Whether we stashed changes
---@field applied_buffers table<integer, boolean> Buffers that have overlays applied
---@field autocmd_id? integer Autocmd ID for buffer events
---@field overlays_visible boolean Whether overlays are currently shown

---@class GReviewerReviewData
---@field pr GReviewerPR PR metadata
---@field files GReviewerFile[] Changed files
---@field comments? GReviewerComment[] Existing comments

---@class GReviewerDiffData
---@field git_root string Git root directory
---@field files GReviewerFile[] Changed files

---@class GReviewerState
---@field active_review? GReviewerReview

---@class GReviewerStateModule
local M = {}

---@type GReviewerState
local state = {
    active_review = nil,
}

---@param review_data GReviewerReviewData
---@param git_root string?
---@return GReviewerReview
function M.set_review(review_data, git_root)
    local files_by_path = {}
    for _, file in ipairs(review_data.files) do
        files_by_path[file.path] = file
    end

    state.active_review = {
        review_type = "pr",
        pr = review_data.pr,
        viewer = review_data.viewer,
        git_root = git_root,
        files = review_data.files,
        files_by_path = files_by_path,
        comments = review_data.comments or {},
        current_file_idx = 1,
        expanded_hunks = {},
        did_checkout = false,
        prev_branch = nil,
        did_stash = false,
        applied_buffers = {},
        autocmd_id = nil,
        overlays_visible = true,
        show_old_code = false,
    }
    return state.active_review
end

---@param diff_data GReviewerDiffData
---@return GReviewerReview
function M.set_local_review(diff_data)
    local files_by_path = {}
    for _, file in ipairs(diff_data.files) do
        files_by_path[file.path] = file
    end

    state.active_review = {
        review_type = "local",
        git_root = diff_data.git_root,
        files = diff_data.files,
        files_by_path = files_by_path,
        comments = {},
        current_file_idx = 1,
        expanded_hunks = {},
        applied_buffers = {},
        autocmd_id = nil,
        overlays_visible = true,
        show_old_code = false,
    }
    return state.active_review
end

---@return boolean
function M.is_local_review()
    if state.active_review then
        return state.active_review.review_type == "local"
    end
    return false
end

---@return string?
function M.get_git_root()
    if state.active_review then
        return state.active_review.git_root
    end
    return nil
end

---@param prev_branch string
---@param stashed boolean
function M.set_checkout_state(prev_branch, stashed)
    if state.active_review then
        state.active_review.did_checkout = true
        state.active_review.prev_branch = prev_branch
        state.active_review.did_stash = stashed
    end
end

---@param path string
---@return GReviewerFile?
function M.get_file_by_path(path)
    if state.active_review and state.active_review.files_by_path then
        return state.active_review.files_by_path[path]
    end
    return nil
end

---@param bufnr integer
function M.mark_buffer_applied(bufnr)
    if state.active_review then
        state.active_review.applied_buffers[bufnr] = true
    end
end

---@param bufnr integer
---@return boolean
function M.is_buffer_applied(bufnr)
    if state.active_review then
        return state.active_review.applied_buffers[bufnr] == true
    end
    return false
end

---@param id integer
function M.set_autocmd_id(id)
    if state.active_review then
        state.active_review.autocmd_id = id
    end
end

---@return GReviewerReview?
function M.get_review()
    return state.active_review
end

function M.clear_review()
    if state.active_review then
        if state.active_review.autocmd_id then
            vim.api.nvim_del_autocmd(state.active_review.autocmd_id)
        end
        for bufnr, _ in pairs(state.active_review.applied_buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                local signs = require("greviewer.ui.signs")
                local virtual = require("greviewer.ui.virtual")
                local comments = require("greviewer.ui.comments")
                signs.clear(bufnr)
                virtual.clear(bufnr)
                comments.clear(bufnr)
            end
        end
    end
    state.active_review = nil
end

---@return GReviewerFile?
function M.get_current_file()
    local review = state.active_review
    if not review then
        return nil
    end
    return review.files[review.current_file_idx]
end

---@param idx integer
function M.set_current_file_idx(idx)
    if state.active_review then
        state.active_review.current_file_idx = idx
    end
end

---@param file_path string
---@param hunk_start integer
---@return boolean
function M.is_hunk_expanded(file_path, hunk_start)
    if state.active_review then
        local key = file_path .. ":" .. hunk_start
        local extmarks = state.active_review.expanded_hunks[key]
        return extmarks ~= nil and #extmarks > 0
    end
    return false
end

---@param file_path string
---@param hunk_start integer
---@param extmark_ids? integer[]
function M.set_hunk_expanded(file_path, hunk_start, extmark_ids)
    if state.active_review then
        local key = file_path .. ":" .. hunk_start
        state.active_review.expanded_hunks[key] = extmark_ids
    end
end

---@param file_path string
---@param hunk_start integer
---@return integer[]?
function M.get_hunk_extmarks(file_path, hunk_start)
    if state.active_review then
        local key = file_path .. ":" .. hunk_start
        return state.active_review.expanded_hunks[key]
    end
    return nil
end

---@param file_path string
---@return GReviewerComment[]
function M.get_comments_for_file(file_path)
    if not state.active_review then
        return {}
    end
    local file_comments = {}
    for _, comment in ipairs(state.active_review.comments) do
        if comment.path == file_path then
            table.insert(file_comments, comment)
        end
    end
    return file_comments
end

---@param comment GReviewerComment
function M.add_comment(comment)
    if state.active_review then
        table.insert(state.active_review.comments, comment)
    end
end

---@return boolean
function M.are_overlays_visible()
    if state.active_review then
        return state.active_review.overlays_visible
    end
    return false
end

---@param visible boolean
function M.set_overlays_visible(visible)
    if state.active_review then
        state.active_review.overlays_visible = visible
    end
end

function M.hide_overlays()
    if not state.active_review then
        return
    end

    if state.active_review.autocmd_id then
        vim.api.nvim_del_autocmd(state.active_review.autocmd_id)
        state.active_review.autocmd_id = nil
    end

    local signs = require("greviewer.ui.signs")
    local virtual = require("greviewer.ui.virtual")
    local comments = require("greviewer.ui.comments")

    for bufnr, _ in pairs(state.active_review.applied_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            signs.clear(bufnr)
            virtual.clear(bufnr)
            comments.clear(bufnr)
        end
    end

    state.active_review.applied_buffers = {}
    state.active_review.overlays_visible = false
end

---@return table<integer, boolean>
function M.get_applied_buffers()
    if state.active_review then
        return state.active_review.applied_buffers
    end
    return {}
end

function M.is_showing_old_code()
    if state.active_review then
        return state.active_review.show_old_code
    end
    return false
end

function M.set_show_old_code(show)
    if state.active_review then
        state.active_review.show_old_code = show
    end
end

return M
