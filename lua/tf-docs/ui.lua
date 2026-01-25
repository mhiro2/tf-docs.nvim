local config = require("tf-docs.config")
local log = require("tf-docs.log")

local M = {}

local peek_win ---@type number|nil
local peek_buf ---@type number|nil
local select_win ---@type number|nil
local select_buf ---@type number|nil
-- selene: allow(unused_variable)
-- Used to keep reference to callback for cleanup
local select_callback_ ---@type fun(item: any|nil)|nil
local select_ns = vim.api.nvim_create_namespace("tfdocs_select")

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

---@param text string
---@param width number
---@return string
local function pad_right(text, width)
  local current = vim.api.nvim_strwidth(text)
  if current >= width then
    return text
  end
  return text .. string.rep(" ", width - current)
end

---@param lines string[]
---@param opts { filetype?: string }|nil
local function open_peek(lines, opts)
  close_peek()
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  peek_buf = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = opts.filetype or "tf-docs"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end

  local height = #lines
  local win_opts = {
    relative = "cursor",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.8)),
    height = math.min(height, math.floor(vim.o.lines * 0.5)),
    row = 1,
    col = 1,
    style = "minimal",
    border = "rounded",
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
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
  open_peek(lines, { filetype = "tf-docs" })
end

---@param versions table<string, string>
---@param root string|nil
---@param meta table<string, TfDocsLockfileMeta>|nil
---@param has_lockfile boolean|nil
---@return string[]
function M._build_versions_lines(versions, root, meta, has_lockfile)
  local lines = {
    "tf-docs.nvim - Provider Versions",
    "",
    string.format("Root: %s", root or "(none)"),
  }

  local lockfile_note = has_lockfile and ".terraform.lock.hcl" or ".terraform.lock.hcl (missing)"
  table.insert(lines, string.format("Lockfile: %s", lockfile_note))
  table.insert(lines, "")

  local sources = {}
  for source, _ in pairs(versions) do
    sources[source] = true
  end
  for source, _ in pairs(meta or {}) do
    sources[source] = true
  end

  local sorted = {}
  for source, _ in pairs(sources) do
    table.insert(sorted, source)
  end
  table.sort(sorted, function(a, b)
    return a < b
  end)

  local max_source_width = 0
  for _, source in ipairs(sorted) do
    max_source_width = math.max(max_source_width, vim.api.nvim_strwidth(source))
  end

  for _, source in ipairs(sorted) do
    local item_meta = meta and meta[source] or nil
    local version = versions[source]
    local version_label
    if item_meta and item_meta.version_missing then
      version_label = "(missing)"
    elseif item_meta and item_meta.version_multiple then
      version_label = string.format("%s (multiple)", version or "(missing)")
    else
      version_label = version or "(missing)"
    end

    local line = string.format("%s  %s", pad_right(source, max_source_width), version_label)
    table.insert(lines, line)
  end

  if #sorted == 0 then
    table.insert(lines, "(no providers found)")
  end

  table.insert(lines, "")
  table.insert(lines, "─── Keys: q/<Esc> to close ───")
  return lines
end

---@param versions table<string, string>
---@param root string|nil
---@param meta table<string, TfDocsLockfileMeta>|nil
---@param has_lockfile boolean|nil
function M.show_versions(versions, root, meta, has_lockfile)
  local lines = M._build_versions_lines(versions, root, meta, has_lockfile)
  open_peek(lines, { filetype = "tf-docs" })
end

local function close_select()
  if select_win and vim.api.nvim_win_is_valid(select_win) then
    pcall(vim.api.nvim_win_close, select_win, true)
  end
  if select_buf and vim.api.nvim_buf_is_valid(select_buf) then
    pcall(vim.api.nvim_buf_delete, select_buf, { force = true })
  end
  select_win = nil
  select_buf = nil
  select_callback_ = nil
end

---@param items any[]
---@param opts { prompt: string, format_item: fun(item: any): string }
---@param on_choice fun(item: any|nil)
function M.select(items, opts, on_choice)
  local cfg = config.get()
  local ui_backend = cfg.ui_select_backend or "auto"

  -- Check for external UI plugins (only in auto mode)
  if ui_backend == "auto" then
    -- Check for telescope-ui-select
    local ok_telescope, _ = pcall(require, "telescope")
    if ok_telescope then
      local ok_ext, _ = pcall(require, "telescope._extensions.ui-select")
      if ok_ext then
        vim.ui.select(items, opts, on_choice)
        return
      end
    end

    -- Check for fzf-lua
    local ok_fzf, fzf = pcall(require, "fzf-lua")
    if ok_fzf and fzf.registered_ui_select then
      vim.ui.select(items, opts, on_choice)
      return
    end

    -- Check for snacks.nvim
    local ok_snacks, _ = pcall(require, "snacks.picker")
    if ok_snacks then
      vim.ui.select(items, opts, on_choice)
      return
    end
  end

  -- Built-in simple UI (or when ui_backend == "builtin")
  if #items == 0 then
    on_choice(nil)
    return
  end

  close_select()

  -- Format items with line numbers
  local formatted_items = {}
  for i, item in ipairs(items) do
    local label = opts.format_item(item, i)
    table.insert(formatted_items, string.format("%3d: %s", i, label))
  end

  -- Build display lines with help text at bottom
  local lines = {
    opts.prompt or "Select:",
    "",
  }
  for _, formatted in ipairs(formatted_items) do
    table.insert(lines, formatted)
  end
  table.insert(lines, "")
  table.insert(lines, "─── Keys: j/k or <C-n>/<C-p> to move, <CR> to select, q/<Esc> to cancel ───")

  local buf = vim.api.nvim_create_buf(false, true)
  select_buf = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "tf-docs-select"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  -- Calculate width and height
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end

  local height = math.min(#lines, vim.o.lines - 4)
  width = math.min(width + 4, vim.o.columns - 8)

  local win_opts = {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  select_win = win
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local function set_mark(row, start_col, end_col, hl_group)
    if not (select_buf and vim.api.nvim_buf_is_valid(select_buf)) then
      return
    end
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line then
      return
    end
    local max_col = #line
    local s = math.max(0, math.min(start_col, max_col))
    local e = math.max(0, math.min(end_col, max_col))
    if e <= s then
      return
    end
    vim.api.nvim_buf_set_extmark(buf, select_ns, row, s, {
      hl_group = hl_group,
      end_row = row,
      end_col = e,
    })
  end

  -- Set up syntax highlighting
  local function apply_highlights()
    if not (select_buf and vim.api.nvim_buf_is_valid(select_buf)) then
      return
    end
    local prompt_text = opts.prompt or "Select:"
    local prompt_len = #prompt_text

    -- Highlight prompt line (only if prompt has content)
    if prompt_len > 0 then
      set_mark(0, 0, prompt_len, "Title")
    end

    -- Highlight help line
    local help_row = #lines - 1
    if help_row >= 0 then
      set_mark(help_row, 0, #lines[#lines], "WarningMsg")
    end

    -- Highlight item numbers and labels
    for i = 1, #formatted_items do
      local line_num = i + 1 -- prompt + blank line
      local text = formatted_items[i]
      -- Number format: "  1: label"
      local num_end = text:find(":")
      if num_end then
        -- Highlight number
        set_mark(line_num, 0, num_end, "Number")
        -- Highlight colon separator
        set_mark(line_num, num_end - 1, num_end + 1, "Delimiter")
        -- Highlight label (resource type like [data], [resource], [module])
        local kind_start = text:find("%[")
        if kind_start then
          local kind_end = text:find("%]", kind_start)
          if kind_end then
            set_mark(line_num, kind_start - 1, kind_end + 1, "Type")
          end
        end
      end
    end
  end

  -- Apply highlights after window is rendered
  vim.schedule(apply_highlights)

  -- Set initial cursor position (first item)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  select_callback_ = on_choice

  -- Key mappings
  local function select_by_cursor()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local index = row - 2
    if index >= 1 and index <= #items then
      close_select()
      on_choice(items[index])
    end
  end

  local function cancel()
    close_select()
    on_choice(nil)
  end

  vim.keymap.set("n", "<CR>", select_by_cursor, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "j", "<Cmd>normal! j<CR>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "k", "<Cmd>normal! k<CR>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<C-n>", "<Cmd>normal! j<CR>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<C-p>", "<Cmd>normal! k<CR>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true })

  -- Cleanup on buffer leave
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    once = true,
    callback = close_select,
  })
end

return M
