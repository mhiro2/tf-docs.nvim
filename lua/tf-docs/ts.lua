local M = {}
local hcl = require("tf-docs.hcl")

---@class TfDocsContext
---@field kind "resource"|"data"|"module"
---@field type string|nil
---@field module_source string|nil
---@field provider_hint string|nil
---@field anchor_candidate string|nil

---@class TfDocsContextCacheEntry
---@field row number
---@field col number
---@field changedtick number
---@field context TfDocsContext|nil

local context_cache = {} ---@type table<number, TfDocsContextCacheEntry>

-- The cache is keyed by (cursor position, changedtick): both uniquely determine
-- the resolved context, so no time-based expiry is needed. Stale entries are
-- dropped on changedtick mismatch here, and on buffer wipe / file rename /
-- :TfDocClearCache via clear_buf_context / clear_context_cache.

---@param bufnr number
---@param cursor integer[]
---@return boolean, TfDocsContext|nil
local function get_cached_context(bufnr, cursor)
  local entry = context_cache[bufnr]
  if not entry then
    return false, nil
  end

  if entry.row ~= cursor[1] or entry.col ~= cursor[2] then
    return false, nil
  end

  -- The buffer may have been wiped and its number reused; guard the lookup.
  local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
  if not ok then
    context_cache[bufnr] = nil
    return false, nil
  end
  if entry.changedtick ~= changedtick then
    context_cache[bufnr] = nil
    return false, nil
  end

  return true, entry.context
end

---@param bufnr number
---@param cursor integer[]
---@param context TfDocsContext|nil
local function set_cached_context(bufnr, cursor, context)
  local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
  if not ok then
    return
  end
  context_cache[bufnr] = {
    row = cursor[1],
    col = cursor[2],
    changedtick = changedtick,
    context = context,
  }
end

-- Block keywords are never valid anchor candidates (they introduce a block,
-- not an argument/attribute), so exclude them in one place.
local BLOCK_KEYWORDS = { resource = true, data = true, module = true }

---@param line string
---@return string|nil
local function anchor_from_line(line)
  local key = line:match("^%s*([%w_%-]+)%s*=")
  if not key then
    key = line:match("^%s*([%w_%-]+)%s*{")
  end
  if not key or BLOCK_KEYWORDS[key] then
    return nil
  end
  return key
end

---@class TfDocsHeader
---@field kind "resource"|"data"|"module"
---@field type string|nil
---@field name string

-- Match a Terraform block header line and extract its kind/type/name.
-- Shared by the treesitter path, the upward-scan fallback, and list_resources.
---@param line string
---@return TfDocsHeader|nil
local function match_header(line)
  local type_name, name = line:match('^%s*resource%s+"([^"]+)"%s+"([^"]+)"')
  if type_name then
    return { kind = "resource", type = type_name, name = name }
  end

  type_name, name = line:match('^%s*data%s+"([^"]+)"%s+"([^"]+)"')
  if type_name then
    return { kind = "data", type = type_name, name = name }
  end

  name = line:match('^%s*module%s+"([^"]+)"')
  if name then
    return { kind = "module", type = nil, name = name }
  end

  return nil
end

---@param block_text string
---@return string|nil
local function provider_hint_from_block_text(block_text)
  local tokens = hcl.tokenize(block_text)
  local i = 1
  local n = #tokens
  local depth = 0
  local started = false
  while i <= n do
    local t = tokens[i]
    if t.kind == "symbol" and t.value == "{" then
      depth = depth + 1
      started = true
      i = i + 1
    elseif t.kind == "symbol" and t.value == "}" then
      depth = math.max(0, depth - 1)
      i = i + 1
      if started and depth == 0 then
        break
      end
    elseif depth == 1 and t.kind == "ident" and t.value == "provider" then
      local eq = tokens[i + 1]
      local v1 = tokens[i + 2]
      if eq and eq.kind == "symbol" and eq.value == "=" and v1 and v1.kind == "ident" then
        return v1.value
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil
end

---@param bufnr number
---@param cursor_pos integer[]|nil
---@return TfDocsContext|nil
local function get_context_treesitter(bufnr, cursor_pos)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end

  -- In minimal test environments (for example, -u tests/minimal_init.lua), parser may be unavailable.
  local ok_parser, parser = pcall(function()
    return vim.treesitter.get_parser(bufnr, "terraform")
  end)
  if not ok_parser or not parser then
    ok_parser, parser = pcall(function()
      return vim.treesitter.get_parser(bufnr, "hcl")
    end)
  end
  if not ok_parser or not parser then
    ok_parser, parser = pcall(function()
      return vim.treesitter.get_parser(bufnr)
    end)
  end
  if not ok_parser or not parser then
    return nil
  end

  local ok_trees, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_trees or not trees or not trees[1] then
    return nil
  end

  local ok_root, root = pcall(function()
    return trees[1]:root()
  end)
  if not ok_root or not root then
    return nil
  end

  local cursor = cursor_pos or vim.api.nvim_win_get_cursor(0)
  local row0 = cursor[1] - 1
  local col0 = cursor[2]

  local lines_for_anchor = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)
  local anchor = anchor_from_line(lines_for_anchor[1] or "")

  local ok_node, node = pcall(function()
    return root:named_descendant_for_range(row0, col0, row0, col0)
  end)
  if not ok_node or not node then
    return nil
  end

  local function header_line_at(sr)
    local l = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
    return l[1] or ""
  end

  local max_module_scan_lines = 500
  local max_block_scan_lines = 500

  while node do
    local ok_range, sr, _, er, _ = pcall(function()
      return node:range()
    end)
    if not ok_range then
      return nil
    end
    local header = match_header(header_line_at(sr))

    if header and header.kind == "module" then
      local scan_end = math.min(er + 1, sr + max_module_scan_lines)
      local block_lines = vim.api.nvim_buf_get_lines(bufnr, sr, scan_end, false)
      local source
      for i = 2, #block_lines do
        local found = block_lines[i]:match('source%s*=%s*"([^"]+)"')
        if found then
          source = found
          break
        end
      end
      return { kind = "module", type = nil, module_source = source, anchor_candidate = anchor }
    elseif header then
      local scan_end = math.min(er + 1, sr + max_block_scan_lines)
      local block_lines = vim.api.nvim_buf_get_lines(bufnr, sr, scan_end, false)
      local provider_hint = provider_hint_from_block_text(table.concat(block_lines, "\n"))
      return { kind = header.kind, type = header.type, provider_hint = provider_hint, anchor_candidate = anchor }
    end

    local ok_parent, parent = pcall(function()
      return node:parent()
    end)
    if not ok_parent then
      return nil
    end
    node = parent
  end

  return nil
end

---@param bufnr number
---@param cursor_pos integer[]|nil
---@return TfDocsContext|nil
function M.get_context(bufnr, cursor_pos)
  local cursor = cursor_pos or vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  if row < 1 then
    return nil
  end

  local cache_hit, cached_context = get_cached_context(bufnr, cursor)
  if cache_hit then
    return cached_context
  end

  local ctx = get_context_treesitter(bufnr, cursor)
  if ctx then
    set_cached_context(bufnr, cursor, ctx)
    return ctx
  end

  -- Fallback: no parser available or TS failure. Keep it best-effort and robust.
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 or row > line_count then
    set_cached_context(bufnr, cursor, nil)
    return nil
  end

  local current_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""

  local anchor = anchor_from_line(current_line)

  local function count_braces(line)
    local opens = 0
    local closes = 0
    local tokens = hcl.tokenize(line)
    for _, t in ipairs(tokens) do
      if t.kind == "symbol" and t.value == "{" then
        opens = opens + 1
      elseif t.kind == "symbol" and t.value == "}" then
        closes = closes + 1
      end
    end
    return opens, closes
  end

  ---@param start_line number
  ---@return string|nil
  local function find_module_source(start_line)
    local depth = 0
    local source
    -- Read a bounded range starting at module header, then scan until braces close.
    local max_scan = 500
    local start0 = start_line - 1
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local end0 = math.min(start0 + max_scan, total_lines)
    local block_lines = vim.api.nvim_buf_get_lines(bufnr, start0, end0, false)
    for i = 1, #block_lines do
      local line = block_lines[i]
      local opens, closes = count_braces(line)
      depth = depth + opens - closes

      if i > 1 then
        local found = line:match('source%s*=%s*"([^"]+)"')
        if found and not source then
          source = found
        end
      end

      if depth <= 0 and i > 1 then
        break
      end
    end
    return source
  end

  ---@param start_line number
  ---@return string|nil
  local function find_provider_hint(start_line)
    local max_scan = 500
    local start0 = start_line - 1
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local end0 = math.min(start0 + max_scan, total_lines)
    local block_lines = vim.api.nvim_buf_get_lines(bufnr, start0, end0, false)
    return provider_hint_from_block_text(table.concat(block_lines, "\n"))
  end

  local function find_header_upward()
    local chunk_size = 256
    local chunk_end = row
    while chunk_end >= 1 do
      local chunk_start = math.max(1, chunk_end - chunk_size + 1)
      local lines = vim.api.nvim_buf_get_lines(bufnr, chunk_start - 1, chunk_end, false)
      for idx = #lines, 1, -1 do
        local line_number = chunk_start + idx - 1
        local header = match_header(lines[idx])
        if header then
          return { kind = header.kind, type = header.type, line = line_number }
        end
      end
      chunk_end = chunk_start - 1
    end
    return nil
  end

  local header = find_header_upward()
  if not header then
    set_cached_context(bufnr, cursor, nil)
    return nil
  end

  if header.kind == "module" then
    local source = find_module_source(header.line)
    local context = { kind = "module", type = nil, module_source = source, anchor_candidate = anchor }
    set_cached_context(bufnr, cursor, context)
    return context
  end

  local provider_hint = find_provider_hint(header.line)
  local context = {
    kind = header.kind,
    type = header.type,
    provider_hint = provider_hint,
    anchor_candidate = anchor,
  }
  set_cached_context(bufnr, cursor, context)
  return context
end

---Drop the cached context for a single buffer (e.g. on BufWipeout/BufFilePost).
---@param bufnr number
function M.clear_buf_context(bufnr)
  context_cache[bufnr] = nil
end

---Drop all cached contexts (e.g. on :TfDocClearCache).
function M.clear_context_cache()
  context_cache = {}
end

---@class TfDocsResource
---@field kind "resource"|"data"|"module"
---@field type string|nil
---@field name string
---@field line number

---@param bufnr number
---@return TfDocsResource[]
function M.list_resources(bufnr)
  local results = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local header = match_header(line)
    if header then
      table.insert(results, { kind = header.kind, type = header.type, name = header.name, line = i })
    end
  end

  return results
end

return M
