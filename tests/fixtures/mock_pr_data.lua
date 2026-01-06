local M = {}

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
                    deleted_at = { 2 },
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
                },
                {
                    start = 10,
                    count = 1,
                    hunk_type = "change",
                    old_lines = { "old line 10" },
                    added_lines = { 10 },
                    deleted_at = { 10 },
                },
                {
                    start = 20,
                    count = 3,
                    hunk_type = "change",
                    old_lines = { "old 20", "old 21", "old 22" },
                    added_lines = { 20, 21, 22 },
                    deleted_at = { 20 },
                },
            },
        },
    },
    comments = {},
}

return M
