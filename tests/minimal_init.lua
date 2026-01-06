local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd)
vim.opt.runtimepath:prepend(cwd .. "/tests")

package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local plenary_paths = {
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/plugged/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/site/pack/test/start/plenary.nvim"),
}

for _, path in ipairs(plenary_paths) do
    if vim.fn.isdirectory(path) == 1 then
        vim.opt.runtimepath:prepend(path)
        break
    end
end

vim.opt.swapfile = false
vim.opt.shortmess:append("I")

vim.notify = function(msg, level)
    local level_name = ({ "TRACE", "DEBUG", "INFO", "WARN", "ERROR" })[level] or "INFO"
    print(string.format("[%s] %s", level_name, msg))
end
