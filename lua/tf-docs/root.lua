local utils = require("tf-docs.utils")

local M = {}

---@param bufnr number
---@return number
local function resolve_bufnr(bufnr)
  return bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
end

---@param value any
---@param field string
---@return string|nil
local function scope_path(value, field)
  if value == nil then
    return nil
  end
  if type(value) ~= "string" or value == "" then
    error(string.format("tf-docs.nvim: %s must be a non-empty string", field))
  end
  return vim.fs.normalize(value)
end

---@param bufnr number
---@return string|nil
function M.get_module_dir(bufnr)
  local path = vim.api.nvim_buf_get_name(resolve_bufnr(bufnr))
  if path == "" then
    return nil
  end
  return vim.fs.dirname(vim.fs.normalize(path))
end

---@param module_dir string|nil
---@param cfg TfDocsConfig
---@return string|nil
function M.find_workspace_root(module_dir, cfg)
  if not module_dir then
    return nil
  end

  local dir = utils.canonical_path(module_dir)
  while dir do
    -- Directory distance takes precedence. Marker order only breaks ties when
    -- more than one configured marker exists in the same directory.
    for _, marker in ipairs(cfg.root_markers) do
      local stat = vim.uv.fs_stat(vim.fs.joinpath(dir, marker))
      if stat then
        return dir
      end
    end

    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end

  return nil
end

---@param bufnr number
---@param cfg TfDocsConfig
---@param opts TfDocsScopeOpts|nil
---@return { module_dir: string|nil, workspace_root: string|nil }
function M.resolve_scopes(bufnr, cfg, opts)
  bufnr = resolve_bufnr(bufnr)
  opts = opts or {}

  local explicit_module_dir = scope_path(opts.module_dir, "module_dir")
  local explicit_workspace_root = scope_path(opts.workspace_root, "workspace_root")

  local configured = {}
  if cfg.scope_resolver and (not explicit_module_dir or not explicit_workspace_root) then
    configured = cfg.scope_resolver(bufnr) or {}
    if type(configured) ~= "table" then
      error("tf-docs.nvim: scope_resolver must return a table or nil")
    end
  end

  local module_dir = explicit_module_dir
    or scope_path(configured.module_dir, "scope_resolver.module_dir")
    or M.get_module_dir(bufnr)
  local workspace_root = explicit_workspace_root
    or scope_path(configured.workspace_root, "scope_resolver.workspace_root")
    or M.find_workspace_root(module_dir, cfg)

  return { module_dir = module_dir, workspace_root = workspace_root }
end

return M
