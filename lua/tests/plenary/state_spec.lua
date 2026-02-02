local cwd = vim.fn.getcwd()
package.path = cwd .. "/lua/tests/?.lua;" .. cwd .. "/lua/tests/?/init.lua;" .. package.path

local fixtures = require("fixtures.mock_pr_data")
local helpers = require("plenary.helpers")

describe("neo_reviewer.state", function()
    local state

    before_each(function()
        package.loaded["neo_reviewer.state"] = nil
        package.loaded["neo_reviewer.ui.signs"] = nil
        package.loaded["neo_reviewer.ui.virtual"] = nil
        package.loaded["neo_reviewer.ui.comments"] = nil
        package.loaded["neo_reviewer.ui.ai"] = nil
        state = require("neo_reviewer.state")
    end)

    after_each(function()
        state.clear_review()
        state.clear_walkthrough()
        helpers.clear_all_buffers()
    end)

    describe("set_review / get_review", function()
        it("stores and retrieves review data", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_not_nil(review)
            assert.are.equal(123, review.pr.number)
            assert.are.equal("Test PR", review.pr.title)
        end)

        it("returns nil when no review is set", function()
            local review = state.get_review()
            assert.is_nil(review)
        end)

        it("initializes current_file_idx to 1", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.are.equal(1, review.current_file_idx)
        end)

        it("initializes empty applied_buffers table", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_table(review.applied_buffers)
            assert.are.equal(0, vim.tbl_count(review.applied_buffers))
        end)

        it("initializes empty expanded_changes table", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_table(review.expanded_changes)
            assert.are.equal(0, vim.tbl_count(review.expanded_changes))
        end)

        it("builds files_by_path lookup table", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_table(review.files_by_path)
            assert.is_not_nil(review.files_by_path["src/foo.lua"])
            assert.is_not_nil(review.files_by_path["src/bar.lua"])
            assert.are.equal("src/foo.lua", review.files_by_path["src/foo.lua"].path)
        end)

        it("normalizes missing change_blocks to empty table", function()
            local data = {
                pr = { number = 555, title = "Missing blocks" },
                files = {
                    {
                        path = "missing.lua",
                        status = "modified",
                        additions = 0,
                        deletions = 0,
                    },
                },
                comments = {},
            }
            state.set_review(data)

            local review = state.get_review()
            assert.is_table(review.files[1].change_blocks)
            assert.are.equal(0, #review.files[1].change_blocks)
        end)

        it("initializes checkout state to false/nil", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_false(review.did_checkout)
            assert.is_nil(review.prev_branch)
        end)

        it("initializes autocmd_id to nil", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local review = state.get_review()
            assert.is_nil(review.autocmd_id)
        end)
    end)

    describe("clear_review", function()
        it("clears the active review", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)
            assert.is_not_nil(state.get_review())

            state.clear_review()
            assert.is_nil(state.get_review())
        end)

        it("clears overlays from applied buffers", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1", "line 2" })
            state.mark_buffer_applied(bufnr)

            assert.has_no_errors(function()
                state.clear_review()
            end)
        end)

        it("handles already invalid buffers gracefully", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            state.mark_buffer_applied(99999)

            assert.has_no_errors(function()
                state.clear_review()
            end)
        end)

        it("deletes autocmd if set", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
                callback = function() end,
            })
            state.set_autocmd_id(autocmd_id)

            assert.has_no_errors(function()
                state.clear_review()
            end)
        end)

        it("closes AI walkthrough window when clearing review", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)
            state.set_ai_analysis({
                overview = "Test overview",
                steps = {},
            })

            helpers.create_test_buffer({ "line 1", "line 2" })

            local ai_ui = require("neo_reviewer.ui.ai")
            ai_ui.open()

            local function find_ai_window()
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    local buf = vim.api.nvim_win_get_buf(win)
                    if vim.bo[buf].filetype == "neo-reviewer-ai" then
                        return win
                    end
                end
                return nil
            end

            assert.is_not_nil(find_ai_window())

            state.clear_review()

            assert.is_nil(find_ai_window())
        end)
    end)

    describe("get_current_file / set_current_file_idx", function()
        it("returns the current file", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local file = state.get_current_file()
            assert.is_not_nil(file)
            assert.are.equal("src/foo.lua", file.path)
        end)

        it("returns nil when no review is active", function()
            local file = state.get_current_file()
            assert.is_nil(file)
        end)

        it("changes current file with set_current_file_idx", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            state.set_current_file_idx(2)
            local file = state.get_current_file()
            assert.are.equal("src/bar.lua", file.path)
        end)

        it("set_current_file_idx does nothing when no review", function()
            assert.has_no_errors(function()
                state.set_current_file_idx(5)
            end)
        end)
    end)

    describe("walkthrough state", function()
        it("stores and retrieves walkthrough data", function()
            state.set_walkthrough({
                mode = "walkthrough",
                overview = "Walkthrough overview",
                steps = {},
                prompt = "Prompt",
                root = "/repo/root",
            })

            local walkthrough = state.get_walkthrough()
            assert.is_not_nil(walkthrough)
            assert.are.equal("Walkthrough overview", walkthrough.overview)
        end)

        it("clears walkthrough data", function()
            state.set_walkthrough({
                mode = "walkthrough",
                overview = "Walkthrough overview",
                steps = {},
                prompt = "Prompt",
                root = "/repo/root",
            })

            state.clear_walkthrough()
            assert.is_nil(state.get_walkthrough())
        end)

        it("does not clear walkthrough on clear_review", function()
            state.set_walkthrough({
                mode = "walkthrough",
                overview = "Walkthrough overview",
                steps = {},
                prompt = "Prompt",
                root = "/repo/root",
            })

            state.clear_review()
            assert.is_not_nil(state.get_walkthrough())
        end)
    end)

    describe("get_file_by_path", function()
        it("returns file by path from lookup table", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local file = state.get_file_by_path("src/foo.lua")
            assert.is_not_nil(file)
            assert.are.equal("src/foo.lua", file.path)
            assert.are.equal("add", file.status)
        end)

        it("returns nil for unknown path", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local file = state.get_file_by_path("unknown.lua")
            assert.is_nil(file)
        end)

        it("returns nil when no review is active", function()
            local file = state.get_file_by_path("test.lua")
            assert.is_nil(file)
        end)
    end)

    describe("set_checkout_state", function()
        it("sets checkout state correctly", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            state.set_checkout_state("main")

            local review = state.get_review()
            assert.is_true(review.did_checkout)
            assert.are.equal("main", review.prev_branch)
        end)

        it("does nothing when no review is active", function()
            assert.has_no_errors(function()
                state.set_checkout_state("main")
            end)
        end)
    end)

    describe("mark_buffer_applied / is_buffer_applied", function()
        it("tracks applied buffers", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local bufnr = vim.api.nvim_create_buf(false, true)

            assert.is_false(state.is_buffer_applied(bufnr))

            state.mark_buffer_applied(bufnr)

            assert.is_true(state.is_buffer_applied(bufnr))
        end)

        it("returns false for unapplied buffers", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            assert.is_false(state.is_buffer_applied(12345))
        end)

        it("returns false when no review is active", function()
            assert.is_false(state.is_buffer_applied(12345))
        end)

        it("mark_buffer_applied does nothing when no review", function()
            assert.has_no_errors(function()
                state.mark_buffer_applied(12345)
            end)
        end)
    end)

    describe("set_autocmd_id", function()
        it("stores autocmd id", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local autocmd_id = vim.api.nvim_create_autocmd("BufEnter", {
                callback = function() end,
            })
            state.set_autocmd_id(autocmd_id)

            local review = state.get_review()
            assert.are.equal(autocmd_id, review.autocmd_id)
        end)

        it("does nothing when no review is active", function()
            assert.has_no_errors(function()
                state.set_autocmd_id(42)
            end)
        end)
    end)

    describe("is_change_expanded / set_change_expanded", function()
        it("tracks expanded state for change blocks", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            assert.is_false(state.is_change_expanded("test.lua", 10))

            state.set_change_expanded("test.lua", 10, { 1 })
            assert.is_true(state.is_change_expanded("test.lua", 10))

            state.set_change_expanded("test.lua", 10, nil)
            assert.is_false(state.is_change_expanded("test.lua", 10))
        end)

        it("tracks change blocks by file path and start line", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            state.set_change_expanded("file1.lua", 10, { 1 })
            state.set_change_expanded("file2.lua", 10, { 2 })
            state.set_change_expanded("file1.lua", 20, { 3, 4 })

            assert.is_true(state.is_change_expanded("file1.lua", 10))
            assert.is_true(state.is_change_expanded("file2.lua", 10))
            assert.is_true(state.is_change_expanded("file1.lua", 20))
            assert.is_false(state.is_change_expanded("file1.lua", 15))
        end)

        it("returns false when no review is active", function()
            assert.is_false(state.is_change_expanded("test.lua", 10))
        end)

        it("stores and retrieves extmark IDs", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            state.set_change_expanded("test.lua", 10, { 101, 102, 103 })

            local extmarks = state.get_change_extmarks("test.lua", 10)
            assert.are.same({ 101, 102, 103 }, extmarks)
        end)

        it("returns nil extmarks when change block not expanded", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            local extmarks = state.get_change_extmarks("test.lua", 10)
            assert.is_nil(extmarks)
        end)
    end)

    describe("get_comments_for_file / add_comment", function()
        it("returns comments for a specific file", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local comments = state.get_comments_for_file("src/foo.lua")
            assert.are.equal(3, #comments)
            assert.are.equal("Looks good!", comments[1].body)
        end)

        it("returns empty table for file with no comments", function()
            local data = helpers.deep_copy(fixtures.multi_file_pr)
            state.set_review(data)

            local comments = state.get_comments_for_file("src/bar.lua")
            assert.are.equal(0, #comments)
        end)

        it("returns empty table when no review is active", function()
            local comments = state.get_comments_for_file("any.lua")
            assert.are.equal(0, #comments)
        end)

        it("adds new comments", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            state.add_comment({
                id = 999,
                path = "src/main.lua",
                line = 5,
                body = "New comment",
                author = "tester",
            })

            local comments = state.get_comments_for_file("src/main.lua")
            assert.are.equal(1, #comments)
            assert.are.equal("New comment", comments[1].body)
        end)

        it("add_comment does nothing when no review", function()
            assert.has_no_errors(function()
                state.add_comment({ id = 1, body = "test" })
            end)
        end)
    end)

    describe("set_local_review", function()
        it("stores local diff data", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            local review = state.get_review()
            assert.is_not_nil(review)
            assert.are.equal("local", review.review_type)
            assert.are.equal("/tmp/test-repo", review.git_root)
            assert.are.equal(2, #review.files)
        end)

        it("normalizes missing change_blocks for local review", function()
            local data = {
                git_root = "/tmp/test-repo",
                files = {
                    {
                        path = "local.lua",
                        status = "modified",
                        additions = 0,
                        deletions = 0,
                    },
                },
            }
            state.set_local_review(data)

            local review = state.get_review()
            assert.is_table(review.files[1].change_blocks)
            assert.are.equal(0, #review.files[1].change_blocks)
        end)

        it("sets review_type to local", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            assert.is_true(state.is_local_review())
        end)

        it("builds files_by_path lookup", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            local review = state.get_review()
            assert.is_not_nil(review.files_by_path["src/main.lua"])
            assert.is_not_nil(review.files_by_path["src/new.lua"])
        end)

        it("initializes empty comments", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            local review = state.get_review()
            assert.are.equal(0, #review.comments)
        end)

        it("does not have pr field", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            local review = state.get_review()
            assert.is_nil(review.pr)
        end)
    end)

    describe("is_local_review", function()
        it("returns true for local review", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            assert.is_true(state.is_local_review())
        end)

        it("returns false for PR review", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            assert.is_false(state.is_local_review())
        end)

        it("returns false when no review is active", function()
            assert.is_false(state.is_local_review())
        end)
    end)

    describe("get_git_root", function()
        it("returns git root for local review", function()
            local data = helpers.deep_copy(fixtures.local_diff)
            state.set_local_review(data)

            assert.are.equal("/tmp/test-repo", state.get_git_root())
        end)

        it("returns git root for PR review when provided", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data, "/tmp/pr-repo")

            assert.are.equal("/tmp/pr-repo", state.get_git_root())
        end)

        it("returns nil for PR review when not provided", function()
            local data = helpers.deep_copy(fixtures.simple_pr)
            state.set_review(data)

            assert.is_nil(state.get_git_root())
        end)

        it("returns nil when no review is active", function()
            assert.is_nil(state.get_git_root())
        end)

        it("returns walkthrough root when no review is active", function()
            state.set_walkthrough({
                mode = "walkthrough",
                overview = "Walkthrough overview",
                steps = {},
                prompt = "Prompt",
                root = "/tmp/walkthrough-repo",
            })

            assert.are.equal("/tmp/walkthrough-repo", state.get_git_root())
        end)
    end)
end)
