local M = {}

local state = {
    active_review = nil,
}

function M.set_review(review_data)
    local files_by_path = {}
    for _, file in ipairs(review_data.files) do
        files_by_path[file.path] = file
    end

    state.active_review = {
        pr = review_data.pr,
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
    }
    return state.active_review
end

function M.set_checkout_state(prev_branch, stashed)
    if state.active_review then
        state.active_review.did_checkout = true
        state.active_review.prev_branch = prev_branch
        state.active_review.did_stash = stashed
    end
end

function M.get_file_by_path(path)
    if state.active_review and state.active_review.files_by_path then
        return state.active_review.files_by_path[path]
    end
    return nil
end

function M.mark_buffer_applied(bufnr)
    if state.active_review then
        state.active_review.applied_buffers[bufnr] = true
    end
end

function M.is_buffer_applied(bufnr)
    if state.active_review then
        return state.active_review.applied_buffers[bufnr] == true
    end
    return false
end

function M.set_autocmd_id(id)
    if state.active_review then
        state.active_review.autocmd_id = id
    end
end

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

function M.get_current_file()
    local review = state.active_review
    if not review then
        return nil
    end
    return review.files[review.current_file_idx]
end

function M.set_current_file_idx(idx)
    if state.active_review then
        state.active_review.current_file_idx = idx
    end
end

function M.get_file_buffer(file_path)
    if state.active_review then
        return state.active_review.buffers[file_path]
    end
    return nil
end

function M.set_file_buffer(file_path, bufnr)
    if state.active_review then
        state.active_review.buffers[file_path] = bufnr
    end
end

function M.is_hunk_expanded(file_path, hunk_start)
    if state.active_review then
        local key = file_path .. ":" .. hunk_start
        return state.active_review.expanded_hunks[key] == true
    end
    return false
end

function M.set_hunk_expanded(file_path, hunk_start, expanded)
    if state.active_review then
        local key = file_path .. ":" .. hunk_start
        state.active_review.expanded_hunks[key] = expanded
    end
end

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

function M.add_comment(comment)
    if state.active_review then
        table.insert(state.active_review.comments, comment)
    end
end

function M.are_overlays_visible()
    if state.active_review then
        return state.active_review.overlays_visible
    end
    return false
end

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

    state.active_review.overlays_visible = false
end

function M.get_applied_buffers()
    if state.active_review then
        return state.active_review.applied_buffers
    end
    return {}
end

return M
