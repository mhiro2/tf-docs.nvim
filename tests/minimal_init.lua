vim.o.swapfile = false
vim.o.writebackup = false
vim.o.backup = false
vim.o.shadafile = "NONE"

local cwd = vim.fn.getcwd()

vim.opt.rtp:prepend(cwd)
vim.opt.rtp:prepend(cwd .. "/deps/mini.nvim")

vim.g.mapleader = " "
