local config = require("tf-docs.config")
local log = require("tf-docs.log")

local M = {}

local peek_win ---@type number|nil
local peek_buf ---@type number|nil

local function close_peek()
  if peek_win and vim.api.nvim_win_is_valid(peek_win) then
    pcall(vim.api.nvim_win_close, peek_win, true)
  end
  if peek_buf and vim.api.nvim_buf_is_valid(peek_buf) then
    pcall(vim.api.nvim_buf_delete, peek_buf, { force = true })
  end
  peek_win = nil
  peek_buf = nil
end

---@param url string
---@return boolean
function M.open(url)
  local cfg = config.get()
  if not vim.ui or not vim.ui.open then
    log.log(cfg, "error", "vim.ui.open is unavailable (requires Neovim 0.10+)")
    return false
  end

  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    log.log(cfg, "error", string.format("vim.ui.open failed: %s", tostring(err)))
    return false
  end
  return true
end

---@param url string
function M.copy(url)
  local cfg = config.get()
  local ok_plus = false
  if vim.fn.has("clipboard") == 1 then
    ok_plus = pcall(vim.fn.setreg, "+", url)
  end
  pcall(vim.fn.setreg, '"', url)
  if ok_plus then
    log.log(cfg, "info", "Terraform docs URL copied to clipboard")
  else
    log.log(cfg, "warn", 'Clipboard is unavailable; copied URL to the unnamed register (")')
  end
end

---@param trace TfDocsTrace
function M.peek(trace)
  close_peek()
  local lines = {
    "tf-docs.nvim",
    "",
    string.format("URL: %s", trace.url or "(unresolved)"),
    string.format("Root: %s", trace.root or "(none)"),
    string.format("Kind: %s", trace.kind or "(none)"),
    string.format("Type: %s", trace.type or "(none)"),
    string.format("Module: %s", trace.module_source or "(none)"),
    string.format("Provider: %s", trace.provider_source or "(none)"),
    string.format("Version: %s", trace.provider_version or "(none)"),
    string.format("Anchor: %s", trace.anchor or "(none)"),
    string.format("Reason: %s", trace.reason or "(none)"),
  }

  local buf = vim.api.nvim_create_buf(false, true)
  peek_buf = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "tf-docs"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line)
  end

  local height = #lines
  local opts = {
    relative = "cursor",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.8)),
    height = math.min(height, math.floor(vim.o.lines * 0.5)),
    row = 1,
    col = 1,
    style = "minimal",
    border = "rounded",
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  peek_win = win
  vim.wo[win].wrap = false

  vim.keymap.set("n", "q", close_peek, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close_peek, { buffer = buf, nowait = true, silent = true })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    once = true,
    callback = close_peek,
  })
end

return M
