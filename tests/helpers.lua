local M = {}

function M.fixture_path(...)
  return vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", ...)
end

---@param opts { name?: string, lines?: string[], cursor?: integer[] }|nil
---@param fn fun(bufnr: number): any
---@return any, any, any, any
function M.with_scratch_buf(opts, fn)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  if opts.name then
    vim.api.nvim_buf_set_name(bufnr, opts.name)
  end
  if opts.lines then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
  end
  if opts.cursor then
    vim.api.nvim_win_set_cursor(0, opts.cursor)
  end

  local ok, a, b, c, d = pcall(fn, bufnr)

  pcall(vim.api.nvim_set_current_buf, prev)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

  if not ok then
    error(a)
  end
  return a, b, c, d
end

---@param fn fun(): any
---@return any, any, any, any
function M.with_no_treesitter(fn)
  local saved = vim.treesitter
  vim.treesitter = nil
  local ok, a, b, c, d = pcall(fn)
  vim.treesitter = saved
  if not ok then
    error(a)
  end
  return a, b, c, d
end

---@param mock table
---@param fn fun(): any
---@return any, any, any, any
function M.with_treesitter(mock, fn)
  local saved = vim.treesitter
  vim.treesitter = mock
  local ok, a, b, c, d = pcall(fn)
  vim.treesitter = saved
  if not ok then
    error(a)
  end
  return a, b, c, d
end

---@param patches { target: table, key: string, value: any }[]
---@param fn fun(): any
---@return any, any, any, any
function M.with_patches(patches, fn)
  local originals = {}
  for i, patch in ipairs(patches) do
    originals[i] = patch.target[patch.key]
    patch.target[patch.key] = patch.value
  end

  local ok, a, b, c, d = pcall(fn)

  for i = #patches, 1, -1 do
    local patch = patches[i]
    patch.target[patch.key] = originals[i]
  end

  if not ok then
    error(a)
  end
  return a, b, c, d
end

function M.reset_state()
  local cache = require("tf-docs.cache")
  local config = require("tf-docs.config")
  local lockfile = require("tf-docs.lockfile")
  local ts = require("tf-docs.ts")
  local ui_backend = require("tf-docs.ui_backend")

  cache.clear()
  lockfile.clear_meta()
  config.setup(nil)
  ts._clear_context_cache_for_test()
  ui_backend._clear_cache_for_test()
end

return M
