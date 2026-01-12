local stub = require("luassert.stub")
local spy = require("luassert.spy")

describe("neo_reviewer.cli", function()
    local cli
    local config
    local Job
    local job_instance

    before_each(function()
        package.loaded["neo_reviewer.cli"] = nil
        package.loaded["neo_reviewer.config"] = nil

        config = require("neo_reviewer.config")
        config.setup({ cli_path = "test-cli" })

        job_instance = {
            start = function() end,
            result = function()
                return {}
            end,
            stderr_result = function()
                return {}
            end,
        }

        Job = require("plenary.job")
        stub(Job, "new", function(_, opts)
            job_instance._opts = opts
            return job_instance
        end)

        cli = require("neo_reviewer.cli")
    end)

    after_each(function()
        Job.new:revert()
    end)

    describe("restore_branch", function()
        it("calls git checkout with correct args", function()
            local callback = spy.new(function() end)
            cli.restore_branch("main", false, callback)

            assert.stub(Job.new).was_called(1)
            local opts = job_instance._opts
            assert.are.equal("git", opts.command)
            assert.are.same({ "checkout", "main" }, opts.args)
        end)

        it("returns success on checkout success", function()
            local received_ok, received_err
            cli.restore_branch("main", false, function(ok, err)
                received_ok = ok
                received_err = err
            end)

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_ok ~= nil
            end)

            assert.is_true(received_ok)
            assert.is_nil(received_err)
        end)

        it("returns error on checkout failure", function()
            local received_ok, received_err
            cli.restore_branch("main", false, function(ok, err)
                received_ok = ok
                received_err = err
            end)

            job_instance.stderr_result = function()
                return { "checkout failed" }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 1)
            end)

            vim.wait(100, function()
                return received_ok ~= nil
            end)

            assert.is_false(received_ok)
            assert.is_not_nil(received_err)
            assert.matches("Failed to restore branch", received_err)
        end)
    end)

    describe("fetch_pr", function()
        it("calls CLI with correct command and args", function()
            local callback = spy.new(function() end)
            cli.fetch_pr("https://github.com/owner/repo/pull/123", callback)

            assert.stub(Job.new).was_called(1)
            local opts = job_instance._opts
            assert.are.equal("test-cli", opts.command)
            assert.are.same({ "fetch", "--url", "https://github.com/owner/repo/pull/123" }, opts.args)
        end)

        it("calls callback with parsed data on success", function()
            local received_data, received_err
            local callback = function(data, err)
                received_data = data
                received_err = err
            end

            cli.fetch_pr("https://github.com/owner/repo/pull/123", callback)

            job_instance.result = function()
                return { '{"pr": {"number": 123}, "files": [], "comments": []}' }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_data ~= nil or received_err ~= nil
            end)

            assert.is_not_nil(received_data)
            assert.is_nil(received_err)
            assert.are.equal(123, received_data.pr.number)
        end)

        it("calls callback with error on CLI failure", function()
            local received_data, received_err
            local callback = function(data, err)
                received_data = data
                received_err = err
            end

            cli.fetch_pr("https://github.com/owner/repo/pull/123", callback)

            job_instance.stderr_result = function()
                return { "Error: Not found" }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 1)
            end)

            vim.wait(100, function()
                return received_data ~= nil or received_err ~= nil
            end)

            assert.is_nil(received_data)
            assert.is_not_nil(received_err)
            assert.matches("CLI error", received_err)
        end)

        it("calls callback with error on invalid JSON", function()
            local received_data, received_err
            local callback = function(data, err)
                received_data = data
                received_err = err
            end

            cli.fetch_pr("https://github.com/owner/repo/pull/123", callback)

            job_instance.result = function()
                return { "not valid json" }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_data ~= nil or received_err ~= nil
            end)

            assert.is_nil(received_data)
            assert.is_not_nil(received_err)
            assert.matches("Failed to parse JSON", received_err)
        end)
    end)

    describe("add_comment", function()
        it("calls CLI with correct command and args", function()
            local callback = spy.new(function() end)
            cli.add_comment("https://github.com/owner/repo/pull/123", {
                path = "src/main.lua",
                line = 42,
                side = "RIGHT",
                body = "Great code!",
            }, callback)

            assert.stub(Job.new).was_called(1)
            local opts = job_instance._opts
            assert.are.equal("test-cli", opts.command)
            assert.are.same({
                "comment",
                "--url",
                "https://github.com/owner/repo/pull/123",
                "--path",
                "src/main.lua",
                "--line",
                "42",
                "--side",
                "RIGHT",
                "--body",
                "Great code!",
            }, opts.args)
        end)

        it("calls callback with data on success", function()
            local received_data, received_err
            local callback = function(data, err)
                received_data = data
                received_err = err
            end

            cli.add_comment("url", { path = "p", line = 1, side = "RIGHT", body = "b" }, callback)

            job_instance.result = function()
                return { '{"success": true, "comment_id": 999}' }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_data ~= nil or received_err ~= nil
            end)

            assert.is_not_nil(received_data)
            assert.is_nil(received_err)
            assert.are.equal(999, received_data.comment_id)
        end)
    end)

    describe("fetch_comments", function()
        it("calls CLI with correct command and args", function()
            local callback = spy.new(function() end)
            cli.fetch_comments("https://github.com/owner/repo/pull/123", callback)

            assert.stub(Job.new).was_called(1)
            local opts = job_instance._opts
            assert.are.equal("test-cli", opts.command)
            assert.are.same({ "comments", "--url", "https://github.com/owner/repo/pull/123" }, opts.args)
        end)

        it("returns comments array on success", function()
            local received_data, received_err
            local callback = function(data, err)
                received_data = data
                received_err = err
            end

            cli.fetch_comments("url", callback)

            job_instance.result = function()
                return { '{"comments": [{"id": 1, "body": "test"}]}' }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_data ~= nil or received_err ~= nil
            end)

            assert.is_not_nil(received_data)
            assert.is_nil(received_err)
            assert.are.equal(1, #received_data)
            assert.are.equal("test", received_data[1].body)
        end)
    end)

    describe("check_auth", function()
        it("calls CLI with auth command", function()
            local callback = spy.new(function() end)
            cli.check_auth(callback)

            assert.stub(Job.new).was_called(1)
            local opts = job_instance._opts
            assert.are.equal("test-cli", opts.command)
            assert.are.same({ "auth" }, opts.args)
        end)

        it("returns ok=true on success", function()
            local received_ok, received_output
            local callback = function(ok, output)
                received_ok = ok
                received_output = output
            end

            cli.check_auth(callback)

            job_instance.result = function()
                return { "Authenticated as user" }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 0)
            end)

            vim.wait(100, function()
                return received_ok ~= nil
            end)

            assert.is_true(received_ok)
            assert.are.equal("Authenticated as user", received_output)
        end)

        it("returns ok=false on failure", function()
            local received_ok, received_output
            local callback = function(ok, output)
                received_ok = ok
                received_output = output
            end

            cli.check_auth(callback)

            job_instance.result = function()
                return { "Not authenticated" }
            end

            local on_exit = job_instance._opts.on_exit
            vim.schedule(function()
                on_exit({ result = job_instance.result, stderr_result = job_instance.stderr_result }, 1)
            end)

            vim.wait(100, function()
                return received_ok ~= nil
            end)

            assert.is_false(received_ok)
        end)
    end)
end)
