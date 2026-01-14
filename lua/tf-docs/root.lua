local cache = require("tf-docs.cache")

local M = {}

---@param bufnr number
---@param cfg TfDocsConfig
---@return string|nil
function M.get_root(bufnr, cfg)
  local cached = cache.get_root(bufnr)
  if cached then
    return cached
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end

  local dir = vim.fs.dirname(path)

  for _, marker in ipairs(cfg.root_markers) do
    local found = vim.fs.find(marker, { path = dir, upward = true, limit = 1 })
    if found and found[1] then
      local root = vim.fs.dirname(found[1])
      cache.set_root(bufnr, root)
      return root
    end
  end

  return nil
end

return M
