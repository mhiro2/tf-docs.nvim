local M = {}
local hcl = require("tf-docs.hcl")

---@class TfDocsContext
---@field kind "resource"|"data"|"module"
---@field type string|nil
---@field module_source string|nil
---@field provider_hint string|nil
---@field anchor_candidate string|nil

---@param line string
---@return string|nil
local function anchor_from_line(line)
  local key = line:match("^%s*([%w_%-]+)%s*=")
  if key then
    return key
  end
  key = line:match("^%s*([%w_%-]+)%s*{")
  return key
end

---@param bufnr number
---@return TfDocsContext|nil
local function get_context_treesitter(bufnr)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return nil
  end

  -- NOTE: `-u tests/minimal_init.lua` のような環境では parser が無いので pcall 必須
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

  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end

  local root = trees[1]:root()
  if not root then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row0 = cursor[1] - 1
  local col0 = cursor[2]

  local lines_for_anchor = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)
  local anchor = anchor_from_line(lines_for_anchor[1] or "")
  if anchor == "resource" or anchor == "data" or anchor == "module" then
    anchor = nil
  end

  local node = root:named_descendant_for_range(row0, col0, row0, col0)
  if not node then
    return nil
  end

  local function header_line_at(sr)
    local l = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
    return l[1] or ""
  end

  local max_module_scan_lines = 500
  local max_block_scan_lines = 500

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

  while node do
    local sr, _, er, _ = node:range()
    local line = header_line_at(sr)

    local type_name = line:match('^%s*resource%s+"([^"]+)"%s+"[^"]+"')
    if type_name then
      local scan_end = math.min(er + 1, sr + max_block_scan_lines)
      local block_lines = vim.api.nvim_buf_get_lines(bufnr, sr, scan_end, false)
      local provider_hint = provider_hint_from_block_text(table.concat(block_lines, "\n"))
      return { kind = "resource", type = type_name, provider_hint = provider_hint, anchor_candidate = anchor }
    end

    type_name = line:match('^%s*data%s+"([^"]+)"%s+"[^"]+"')
    if type_name then
      local scan_end = math.min(er + 1, sr + max_block_scan_lines)
      local block_lines = vim.api.nvim_buf_get_lines(bufnr, sr, scan_end, false)
      local provider_hint = provider_hint_from_block_text(table.concat(block_lines, "\n"))
      return { kind = "data", type = type_name, provider_hint = provider_hint, anchor_candidate = anchor }
    end

    if line:match('^%s*module%s+"[^"]+"') then
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
    end

    node = node:parent()
  end

  return nil
end

---@param bufnr number
---@return TfDocsContext|nil
function M.get_context(bufnr)
  local ctx = get_context_treesitter(bufnr)
  if ctx then
    return ctx
  end

  -- Fallback: no parser available or TS failure. Keep it best-effort and robust.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  -- Only read up to the cursor line for upward scanning.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  if #lines == 0 then
    return nil
  end

  local current_line = lines[row] or ""
  local anchor = anchor_from_line(current_line)
  if anchor == "resource" or anchor == "data" or anchor == "module" then
    anchor = nil
  end

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
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local end0 = math.min(start0 + max_scan, line_count)
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

  ---@param start_line number
  ---@return string|nil
  local function find_provider_hint(start_line)
    local max_scan = 500
    local start0 = start_line - 1
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local end0 = math.min(start0 + max_scan, line_count)
    local block_lines = vim.api.nvim_buf_get_lines(bufnr, start0, end0, false)
    return provider_hint_from_block_text(table.concat(block_lines, "\n"))
  end

  for i = row, 1, -1 do
    local line = lines[i]
    local kind, type_name = line:match('^%s*(resource)%s+"([^"]+)"%s+"[^"]+"')
    if kind and type_name then
      local provider_hint = find_provider_hint(i)
      return { kind = kind, type = type_name, provider_hint = provider_hint, anchor_candidate = anchor }
    end

    kind, type_name = line:match('^%s*(data)%s+"([^"]+)"%s+"[^"]+"')
    if kind and type_name then
      local provider_hint = find_provider_hint(i)
      return { kind = kind, type = type_name, provider_hint = provider_hint, anchor_candidate = anchor }
    end

    local module_kind = line:match('^%s*(module)%s+"[^"]+"')
    if module_kind then
      local source = find_module_source(i)
      return { kind = "module", type = nil, module_source = source, anchor_candidate = anchor }
    end
  end

  return nil
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
    local kind, type_name, name = line:match('^%s*(resource)%s+"([^"]+)"%s+"([^"]+)"')
    if kind and type_name and name then
      table.insert(results, { kind = kind, type = type_name, name = name, line = i })
    else
      kind, type_name, name = line:match('^%s*(data)%s+"([^"]+)"%s+"([^"]+)"')
      if kind and type_name and name then
        table.insert(results, { kind = kind, type = type_name, name = name, line = i })
      else
        kind, name = line:match('^%s*(module)%s+"([^"]+)"')
        if kind and name then
          table.insert(results, { kind = kind, type = nil, name = name, line = i })
        end
      end
    end
  end

  return results
end

return M
