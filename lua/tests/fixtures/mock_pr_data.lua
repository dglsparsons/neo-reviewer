local M = {}

---@param hunks table[]
---@return table[]
local function build_change_blocks_from_hunks(hunks)
    local blocks = {}

    for _, hunk in ipairs(hunks or {}) do
        -- context_breaks forces a split even when positions are contiguous (simulates context lines).
        ---@type table<integer, boolean>
        local context_breaks = {}
        for _, line in ipairs(hunk.context_breaks or {}) do
            context_breaks[line] = true
        end

        ---@type table<integer, boolean>
        local positions = {}
        for _, line in ipairs(hunk.added_lines or {}) do
            positions[line] = true
        end
        for _, line in ipairs(hunk.deleted_at or {}) do
            positions[line] = true
        end

        ---@type integer[]
        local sorted = {}
        for line, _ in pairs(positions) do
            table.insert(sorted, line)
        end
        table.sort(sorted)

        local runs = {}
        local run_start = nil
        local run_end = nil
        for _, line in ipairs(sorted) do
            if not run_start then
                run_start = line
                run_end = line
            elseif line == run_end + 1 and not context_breaks[line] then
                run_end = line
            else
                table.insert(runs, { run_start, run_end })
                run_start = line
                run_end = line
            end
        end
        if run_start then
            table.insert(runs, { run_start, run_end })
        end

        for _, run in ipairs(runs) do
            local start_line = run[1]
            local end_line = run[2]

            ---@type integer[]
            local added_lines = {}
            for _, ln in ipairs(hunk.added_lines or {}) do
                if ln >= start_line and ln <= end_line then
                    table.insert(added_lines, ln)
                end
            end

            ---@type integer[]
            local changed_lines = {}
            for _, ln in ipairs(hunk.changed_lines or {}) do
                if ln >= start_line and ln <= end_line then
                    table.insert(changed_lines, ln)
                end
            end

            ---@type table[]
            local deletion_groups = {}
            ---@type table?
            local current_group = nil

            ---@type table[]
            local old_to_new = {}

            for i, old_line in ipairs(hunk.old_lines or {}) do
                local anchor = (hunk.deleted_at and hunk.deleted_at[i]) or start_line
                local old_line_number = hunk.deleted_old_lines and hunk.deleted_old_lines[i] or nil

                if anchor >= start_line and anchor <= end_line then
                    if current_group and current_group.anchor_line == anchor then
                        table.insert(current_group.old_lines, old_line)
                        if old_line_number then
                            table.insert(current_group.old_line_numbers, old_line_number)
                        end
                    else
                        current_group = {
                            anchor_line = anchor,
                            old_lines = { old_line },
                            old_line_numbers = {},
                        }
                        if old_line_number then
                            table.insert(current_group.old_line_numbers, old_line_number)
                        end
                        table.insert(deletion_groups, current_group)
                    end

                    if old_line_number then
                        table.insert(old_to_new, { old_line = old_line_number, new_line = anchor })
                    end
                end
            end

            local kind = hunk.hunk_type
            if #added_lines > 0 and #deletion_groups > 0 then
                kind = "change"
            elseif #added_lines > 0 then
                kind = "add"
            elseif #deletion_groups > 0 then
                kind = "delete"
            end

            table.insert(blocks, {
                start_line = start_line,
                end_line = end_line,
                kind = kind,
                added_lines = added_lines,
                changed_lines = changed_lines,
                deletion_groups = deletion_groups,
                old_to_new = old_to_new,
            })
        end
    end

    return blocks
end

local function normalize_fixtures(fixtures)
    for _, data in pairs(fixtures) do
        if type(data) == "table" and data.files then
            for _, file in ipairs(data.files) do
                if file.hunks then
                    file.change_blocks = build_change_blocks_from_hunks(file.hunks)
                    file.hunks = nil
                elseif not file.change_blocks then
                    file.change_blocks = {}
                end
            end
        end
    end
end

M.simple_pr = {
    pr = {
        number = 123,
        title = "Test PR",
        body = "This is a test PR",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "src/main.lua",
            status = "modified",
            additions = 5,
            deletions = 2,
            content = "line 1\nline 2\nline 3\nline 4\nline 5",
            hunks = {
                {
                    start = 2,
                    count = 2,
                    hunk_type = "change",
                    old_lines = { "old line 2", "old line 3" },
                    added_lines = { 2, 3 },
                    deleted_at = { 2, 2 },
                    deleted_old_lines = { 2, 3 },
                },
            },
        },
    },
    comments = {},
}

M.multi_file_pr = {
    pr = {
        number = 456,
        title = "Multi-file PR",
        body = "PR with multiple files",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "src/foo.lua",
            status = "add",
            additions = 10,
            deletions = 0,
            content = "new file\nline 2\nline 3",
            hunks = {
                {
                    start = 1,
                    count = 3,
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 1, 2, 3 },
                    deleted_at = {},
                    deleted_old_lines = {},
                },
            },
        },
        {
            path = "src/bar.lua",
            status = "modified",
            additions = 3,
            deletions = 1,
            content = "modified\nline 2",
            hunks = {
                {
                    start = 1,
                    count = 1,
                    hunk_type = "change",
                    old_lines = { "original" },
                    added_lines = { 1 },
                    deleted_at = { 1 },
                    deleted_old_lines = { 1 },
                },
            },
        },
        {
            path = "src/deleted.lua",
            status = "deleted",
            additions = 0,
            deletions = 5,
            content = nil,
            hunks = {
                {
                    start = 1,
                    count = 0,
                    hunk_type = "delete",
                    old_lines = { "was here", "line 2", "line 3", "line 4", "line 5" },
                    added_lines = {},
                    deleted_at = { 1 },
                    deleted_old_lines = { 1, 2, 3, 4, 5 },
                },
            },
        },
    },
    comments = {
        {
            id = 1,
            path = "src/foo.lua",
            line = 2,
            side = "RIGHT",
            body = "Looks good!",
            author = "reviewer",
            created_at = "2024-01-01T12:00:00Z",
            html_url = "https://github.com/owner/repo/pull/456#discussion_r1",
            in_reply_to_id = nil,
        },
        {
            id = 2,
            path = "src/foo.lua",
            line = 2,
            side = "RIGHT",
            body = "Thanks! I appreciate the feedback.",
            author = "author",
            created_at = "2024-01-01T13:00:00Z",
            html_url = "https://github.com/owner/repo/pull/456#discussion_r2",
            in_reply_to_id = 1,
        },
        {
            id = 3,
            path = "src/foo.lua",
            line = 2,
            side = "RIGHT",
            body = "No problem, one small thing though - could you add a test?",
            author = "reviewer",
            created_at = "2024-01-01T14:00:00Z",
            html_url = "https://github.com/owner/repo/pull/456#discussion_r3",
            in_reply_to_id = 1,
        },
    },
}

M.navigation_pr = {
    pr = {
        number = 789,
        title = "Navigation test PR",
        body = "PR for testing hunk navigation",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "test.lua",
            status = "modified",
            additions = 10,
            deletions = 5,
            content = table.concat({
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
                "line 9",
                "line 10",
                "line 11",
                "line 12",
                "line 13",
                "line 14",
                "line 15",
                "line 16",
                "line 17",
                "line 18",
                "line 19",
                "line 20",
                "line 21",
                "line 22",
                "line 23",
                "line 24",
                "line 25",
            }, "\n"),
            hunks = {
                {
                    start = 3,
                    count = 2,
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 3, 4 },
                    deleted_at = {},
                    deleted_old_lines = {},
                },
                {
                    start = 10,
                    count = 1,
                    hunk_type = "change",
                    old_lines = { "old line 10" },
                    added_lines = { 10 },
                    deleted_at = { 10 },
                    deleted_old_lines = { 10 },
                },
                {
                    start = 20,
                    count = 3,
                    hunk_type = "change",
                    old_lines = { "old 20", "old 21", "old 22" },
                    added_lines = { 20, 21, 22 },
                    deleted_at = { 20, 20, 20 },
                    deleted_old_lines = { 20, 21, 22 },
                },
            },
        },
    },
    comments = {},
}

M.context_split_pr = {
    pr = {
        number = 790,
        title = "Context split PR",
        body = "PR for testing context-based change block splits",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "context_split.lua",
            status = "modified",
            additions = 0,
            deletions = 2,
            content = table.concat({
                "context line 1",
                "context line 2",
            }, "\n"),
            hunks = {
                {
                    start = 1,
                    count = 2,
                    hunk_type = "delete",
                    old_lines = { "old line 1", "old line 3" },
                    added_lines = {},
                    deleted_at = { 1, 2 },
                    deleted_old_lines = { 1, 3 },
                    context_breaks = { 2 },
                },
            },
        },
    },
    comments = {},
}

M.mixed_changes_pr = {
    pr = {
        number = 999,
        title = "Mixed changes PR",
        body = "PR with non-contiguous deletions",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "mixed.lua",
            status = "modified",
            additions = 4,
            deletions = 3,
            content = table.concat({
                "new line 1",
                "new line 2",
                "context 1",
                "context 2",
                "new line 5",
                "new line 6",
            }, "\n"),
            hunks = {
                {
                    start = 1,
                    count = 6,
                    hunk_type = "change",
                    old_lines = { "old line 1", "old line 2", "old line 5" },
                    added_lines = { 1, 2, 5, 6 },
                    deleted_at = { 1, 1, 5 },
                    deleted_old_lines = { 1, 2, 5 },
                },
            },
        },
    },
    comments = {},
}

M.local_diff = {
    git_root = "/tmp/test-repo",
    files = {
        {
            path = "src/main.lua",
            status = "modified",
            additions = 5,
            deletions = 2,
            hunks = {
                {
                    start = 2,
                    count = 2,
                    hunk_type = "change",
                    old_lines = { "old line 2", "old line 3" },
                    added_lines = { 2, 3 },
                    deleted_at = { 2, 2 },
                    deleted_old_lines = { 2, 3 },
                },
            },
        },
        {
            path = "src/new.lua",
            status = "added",
            additions = 10,
            deletions = 0,
            hunks = {
                {
                    start = 1,
                    count = 10,
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
                    deleted_at = {},
                    deleted_old_lines = {},
                },
            },
        },
    },
}

M.comment_navigation_pr = {
    pr = {
        number = 888,
        title = "Comment navigation test PR",
        body = "PR for testing comment navigation",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "test.lua",
            status = "modified",
            additions = 10,
            deletions = 5,
            content = table.concat({
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
                "line 9",
                "line 10",
                "line 11",
                "line 12",
                "line 13",
                "line 14",
                "line 15",
                "line 16",
                "line 17",
                "line 18",
                "line 19",
                "line 20",
                "line 21",
                "line 22",
                "line 23",
                "line 24",
                "line 25",
            }, "\n"),
            hunks = {
                {
                    start = 3,
                    count = 2,
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 3, 4 },
                    deleted_at = {},
                    deleted_old_lines = {},
                },
                {
                    start = 10,
                    count = 1,
                    hunk_type = "change",
                    old_lines = { "old line 10" },
                    added_lines = { 10 },
                    deleted_at = { 10 },
                    deleted_old_lines = { 10 },
                },
                {
                    start = 20,
                    count = 3,
                    hunk_type = "change",
                    old_lines = { "old 20", "old 21", "old 22" },
                    added_lines = { 20, 21, 22 },
                    deleted_at = { 20, 20, 20 },
                    deleted_old_lines = { 20, 21, 22 },
                },
            },
        },
    },
    comments = {
        {
            id = 101,
            path = "test.lua",
            line = 5,
            side = "RIGHT",
            body = "First comment",
            author = "reviewer1",
            created_at = "2024-01-01T12:00:00Z",
            html_url = "https://github.com/owner/repo/pull/888#discussion_r101",
        },
        {
            id = 102,
            path = "test.lua",
            line = 5,
            side = "RIGHT",
            body = "Reply to first",
            author = "author",
            created_at = "2024-01-01T13:00:00Z",
            html_url = "https://github.com/owner/repo/pull/888#discussion_r102",
            in_reply_to_id = 101,
        },
        {
            id = 103,
            path = "test.lua",
            line = 15,
            side = "RIGHT",
            body = "Second comment",
            author = "reviewer2",
            created_at = "2024-01-01T14:00:00Z",
            html_url = "https://github.com/owner/repo/pull/888#discussion_r103",
        },
        {
            id = 104,
            path = "test.lua",
            line = 22,
            side = "RIGHT",
            body = "Third comment",
            author = "reviewer1",
            created_at = "2024-01-01T15:00:00Z",
            html_url = "https://github.com/owner/repo/pull/888#discussion_r104",
        },
    },
}

M.suggestion_pr = {
    pr = {
        number = 1001,
        title = "PR with suggestions",
        body = "PR containing code suggestions",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "src/example.lua",
            status = "modified",
            additions = 5,
            deletions = 2,
            content = table.concat({
                "local M = {}",
                "",
                "local x = foo()",
                "",
                "function M.setup()",
                "    print('hello')",
                "    print('world')",
                "end",
                "",
                "return M",
            }, "\n"),
            hunks = {
                {
                    start = 3,
                    count = 1,
                    hunk_type = "add",
                    old_lines = {},
                    added_lines = { 3 },
                    deleted_at = {},
                    deleted_old_lines = {},
                },
                {
                    start = 6,
                    count = 2,
                    hunk_type = "change",
                    old_lines = { "    print('old')" },
                    added_lines = { 6, 7 },
                    deleted_at = { 6 },
                    deleted_old_lines = { 6 },
                },
            },
        },
    },
    comments = {
        {
            id = 100,
            path = "src/example.lua",
            line = 3,
            side = "RIGHT",
            body = "Consider using a more descriptive name:\n\n```suggestion\nlocal descriptive_name = foo()\n```",
            author = "reviewer",
            created_at = "2024-01-15T10:30:00Z",
            html_url = "https://github.com/owner/repo/pull/1001#discussion_r100",
            in_reply_to_id = nil,
        },
        {
            id = 101,
            path = "src/example.lua",
            line = 7,
            start_line = 6,
            side = "RIGHT",
            start_side = "RIGHT",
            body = "These print statements could be combined:\n\n```suggestion\n    print('hello world')\n```\n\nThis reduces the number of function calls.",
            author = "reviewer",
            created_at = "2024-01-15T11:00:00Z",
            html_url = "https://github.com/owner/repo/pull/1001#discussion_r101",
            in_reply_to_id = nil,
        },
        {
            id = 102,
            path = "src/example.lua",
            line = 3,
            side = "RIGHT",
            body = "Good suggestion, I'll update this.",
            author = "author",
            created_at = "2024-01-15T12:00:00Z",
            html_url = "https://github.com/owner/repo/pull/1001#discussion_r102",
            in_reply_to_id = 100,
        },
    },
}

M.multiline_suggestion_pr = {
    pr = {
        number = 1002,
        title = "PR with multi-line suggestion",
        body = "PR with a multi-line code suggestion",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "src/config.lua",
            status = "modified",
            additions = 3,
            deletions = 1,
            content = table.concat({
                "local config = {",
                "    name = 'test',",
                "    value = 42,",
                "}",
            }, "\n"),
            hunks = {
                {
                    start = 2,
                    count = 2,
                    hunk_type = "change",
                    old_lines = { "    old = true," },
                    added_lines = { 2, 3 },
                    deleted_at = { 2 },
                    deleted_old_lines = { 2 },
                },
            },
        },
    },
    comments = {
        {
            id = 200,
            path = "src/config.lua",
            line = 3,
            start_line = 2,
            side = "RIGHT",
            start_side = "RIGHT",
            body = "Let's add some more fields:\n\n```suggestion\n    name = 'test',\n    value = 42,\n    enabled = true,\n    debug = false,\n```",
            author = "reviewer",
            created_at = "2024-01-16T09:00:00Z",
            html_url = "https://github.com/owner/repo/pull/1002#discussion_r200",
            in_reply_to_id = nil,
        },
    },
}

M.delete_only_pr = {
    pr = {
        number = 1100,
        title = "Delete only PR",
        body = "PR with DELETE-only hunks",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "deleted_lines.lua",
            status = "modified",
            additions = 0,
            deletions = 3,
            content = table.concat({
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
            }, "\n"),
            hunks = {
                {
                    start = 3,
                    count = 0,
                    hunk_type = "delete",
                    old_lines = { "deleted line A", "deleted line B", "deleted line C" },
                    added_lines = {},
                    deleted_at = { 3, 3, 3 },
                    deleted_old_lines = { 3, 4, 5 },
                },
            },
        },
    },
    comments = {},
}

M.change_hunk_pr = {
    pr = {
        number = 1101,
        title = "Change hunk PR",
        body = "PR with CHANGE hunks for anchoring tests",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "changed_file.lua",
            status = "modified",
            additions = 2,
            deletions = 2,
            content = table.concat({
                "line 1",
                "line 2",
                "new line 3",
                "new line 4",
                "line 5",
                "line 6",
                "line 7",
            }, "\n"),
            hunks = {
                {
                    start = 3,
                    count = 2,
                    hunk_type = "change",
                    old_lines = { "old line 3", "old line 4" },
                    added_lines = { 3, 4 },
                    deleted_at = { 3, 3 },
                    deleted_old_lines = { 3, 4 },
                },
            },
        },
    },
    comments = {},
}

M.eof_deletion_pr = {
    pr = {
        number = 1102,
        title = "EOF deletion PR",
        body = "PR with deletions at end of file",
        state = "open",
        author = "testuser",
    },
    files = {
        {
            path = "eof_deleted.lua",
            status = "modified",
            additions = 0,
            deletions = 3,
            -- File now has 3 lines; lines 4-6 were deleted
            content = table.concat({
                "line 1",
                "line 2",
                "line 3",
            }, "\n"),
            hunks = {
                {
                    start = 4,
                    count = 0,
                    hunk_type = "delete",
                    old_lines = { "deleted line 4", "deleted line 5", "deleted line 6" },
                    added_lines = {},
                    deleted_at = { 4, 4, 4 },
                    deleted_old_lines = { 4, 5, 6 },
                },
            },
        },
    },
    comments = {},
}

normalize_fixtures(M)

return M
