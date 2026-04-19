local M = {}

---@return boolean
local function has_min_nvim_version()
  return vim.version.ge(vim.version(), { 0, 12, 0 })
end

---@return boolean
local function has_treesitter_parser()
  if not vim.treesitter or not vim.treesitter.language or not vim.treesitter.language.add then
    return false
  end

  for _, lang in ipairs({ "terraform", "hcl" }) do
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    if ok and loaded then
      return true
    end
  end

  return false
end

function M.check()
  local health = vim.health or require("health")
  health.start("tf-docs")

  if has_min_nvim_version() then
    health.ok("Neovim 0.12+ detected")
  else
    health.error("Neovim 0.12+ required")
  end

  if vim.ui and vim.ui.open then
    health.ok("vim.ui.open available")
  else
    health.error("vim.ui.open is unavailable")
  end

  if has_treesitter_parser() then
    health.ok("treesitter parser available (terraform/hcl, optional)")
  else
    health.warn("treesitter parser not detected; tf-docs will use line-based fallback parsing")
  end
end

return M
