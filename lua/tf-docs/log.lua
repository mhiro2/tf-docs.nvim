local M = {}

local level_map = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local function notify(msg, level)
  if vim.notify then
    vim.notify(msg, level, { title = "tf-docs.nvim" })
  else
    print(msg)
  end
end

---@param cfg TfDocsConfig
---@param level string
---@return boolean
local function should_log(cfg, level)
  local current = level_map[cfg.log_level] or vim.log.levels.WARN
  local target = level_map[level] or vim.log.levels.WARN
  return target >= current
end

---@param cfg TfDocsConfig
---@param level string
---@param msg string
function M.log(cfg, level, msg)
  if should_log(cfg, level) then
    notify(msg, level_map[level] or vim.log.levels.WARN)
  end
end

---@param level string
---@param msg string
function M.log_force(level, msg)
  notify(msg, level_map[level] or vim.log.levels.WARN)
end

return M
