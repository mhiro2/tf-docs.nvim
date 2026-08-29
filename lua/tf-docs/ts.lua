local M = {}
local hcl = require("tf-docs.hcl")

---@class TfDocsContext
---@field kind "resource"|"data"|"module"
---@field type string|nil
---@field module_source string|nil
---@field module_source_reason string|nil
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

---@param node userdata|table
---@return (userdata|table)[]
local function named_children(node)
  local children = {}
  for index = 0, node:named_child_count() - 1 do
    local child = node:named_child(index)
    if child then
      children[#children + 1] = child
    end
  end
  return children
end

---@param bufnr number
---@param node userdata|table
---@return string|nil
local function node_text(bufnr, node)
  if vim.treesitter.get_node_text then
    return vim.treesitter.get_node_text(node, bufnr)
  end

  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
  return table.concat(lines, "\n")
end

---@class TfDocsAstAttribute
---@field name string
---@field expression string

---@param bufnr number
---@param attribute userdata|table
---@return TfDocsAstAttribute|nil
local function ast_attribute(bufnr, attribute)
  local children = named_children(attribute)
  local name
  local expression
  for _, child in ipairs(children) do
    local child_type = child:type()
    if child_type == "identifier" and not name then
      name = node_text(bufnr, child)
    elseif child_type == "expression" and not expression then
      expression = node_text(bufnr, child)
    end
  end

  if not name or not expression then
    return nil
  end
  return { name = name, expression = expression }
end

---@class TfDocsAstBlock
---@field block_type string
---@field labels string[]
---@field body userdata|table|nil

---@param bufnr number
---@param block userdata|table
---@return TfDocsAstBlock|nil
local function ast_block(bufnr, block)
  local children = named_children(block)
  local block_type
  local labels = {}
  local body
  for _, child in ipairs(children) do
    local child_type = child:type()
    if child_type == "identifier" and not block_type then
      block_type = node_text(bufnr, child)
    elseif child_type == "string_lit" then
      local text = node_text(bufnr, child)
      local label = text and hcl.decode_quoted_literal(text) or nil
      if label then
        labels[#labels + 1] = label
      end
    elseif child_type == "body" then
      body = child
    end
  end

  if not block_type then
    return nil
  end
  return { block_type = block_type, labels = labels, body = body }
end

---@param block userdata|table
---@return boolean
local function is_top_level_block(block)
  local body = block:parent()
  if not body then
    return false
  end
  if body:type() ~= "body" then
    return false
  end

  local root = body:parent()
  if not root then
    return false
  end
  return root:type() == "config_file"
end

---@param bufnr number
---@param body userdata|table|nil
---@return table<string, TfDocsAstAttribute>
local function ast_attributes(bufnr, body)
  if not body then
    return {}
  end
  local children = named_children(body)

  local attributes = {}
  for _, child in ipairs(children) do
    if child:type() == "attribute" then
      local attribute = ast_attribute(bufnr, child)
      if attribute and not attributes[attribute.name] then
        attributes[attribute.name] = attribute
      end
    end
  end
  return attributes
end

---@param expression string
---@return string|nil
local function provider_hint_from_expression(expression)
  local tokens = hcl.tokenize(expression)
  if #tokens == 1 and tokens[1].kind == "ident" then
    return tokens[1].value
  end
  if
    #tokens == 3
    and tokens[1].kind == "ident"
    and tokens[2].kind == "symbol"
    and tokens[2].value == "."
    and tokens[3].kind == "ident"
  then
    return tokens[1].value
  end
  return nil
end

---@param bufnr number
---@param node userdata|table
---@return TfDocsContext|nil
local function context_from_ast(bufnr, node)
  local anchor
  local current = node

  while current do
    local current_type = current:type()

    if current_type == "attribute" and not anchor then
      local attribute = ast_attribute(bufnr, current)
      anchor = attribute and attribute.name or nil
    elseif current_type == "block" then
      local block = ast_block(bufnr, current)
      local top_level = is_top_level_block(current)

      if block and top_level and BLOCK_KEYWORDS[block.block_type] then
        local kind = block.block_type
        local required_labels = kind == "module" and 1 or 2
        if #block.labels < required_labels then
          return nil
        end

        local attributes = ast_attributes(bufnr, block.body)
        if kind == "module" then
          local source = attributes.source
          if not source then
            return {
              kind = "module",
              type = nil,
              module_source_reason = "module-source-missing",
              anchor_candidate = anchor,
            }
          end

          local module_source = hcl.decode_quoted_literal(vim.trim(source.expression))
          local module_source_reason
          if not module_source then
            module_source_reason = "module-source-expression"
          end
          return {
            kind = "module",
            type = nil,
            module_source = module_source,
            module_source_reason = module_source_reason,
            anchor_candidate = anchor,
          }
        end

        local provider = attributes.provider
        return {
          kind = kind,
          type = block.labels[1],
          provider_hint = provider and provider_hint_from_expression(provider.expression) or nil,
          anchor_candidate = anchor,
        }
      end

      if block and not anchor and not BLOCK_KEYWORDS[block.block_type] then
        anchor = block.block_type
      end
    end

    current = current:parent()
  end

  return nil
end

---@param bufnr number
---@param cursor_pos integer[]|nil
---@return "ok"|"unavailable"|"error", TfDocsContext|nil
local function get_context_treesitter(bufnr, cursor_pos)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return "unavailable", nil
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
    return "unavailable", nil
  end

  local ok_trees, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_trees or not trees or not trees[1] then
    return "error", nil
  end

  local ok_root, root = pcall(function()
    return trees[1]:root()
  end)
  if not ok_root or not root then
    return "error", nil
  end

  local ok_has_error, has_error = pcall(function()
    return root:has_error()
  end)
  if not ok_has_error or has_error then
    return "error", nil
  end

  local cursor = cursor_pos or vim.api.nvim_win_get_cursor(0)
  local row0 = cursor[1] - 1
  local col0 = cursor[2]

  local ok_node, node = pcall(function()
    return root:named_descendant_for_range(row0, col0, row0, col0)
  end)
  if not ok_node then
    return "error", nil
  end
  if not node then
    return "ok", nil
  end

  local ok_context, context = pcall(context_from_ast, bufnr, node)
  if not ok_context then
    return "error", nil
  end
  return "ok", context
end

---@param structure TfDocsHclStructure
---@param block TfDocsHclStructuralBlock
---@param row number
---@param col number
---@return string|nil
local function anchor_from_structure(structure, block, row, col)
  local tokens = structure.line_tokens[row] or {}
  local min_col = row == block.line and block.start_col or 0
  local max_col = row == block.end_line and math.min(block.end_col, col) or col
  local anchor
  for index, token in ipairs(tokens) do
    local next_token = tokens[index + 1]
    if
      token.col >= min_col
      and token.col <= max_col
      and token.kind == "ident"
      and not BLOCK_KEYWORDS[token.value]
      and next_token
      and next_token.col <= (row == block.end_line and block.end_col or math.huge)
      and next_token.kind == "symbol"
      and (next_token.value == "=" or next_token.value == "{")
    then
      anchor = token.value
    end
  end
  return anchor
end

---@param block TfDocsHclStructuralBlock
---@param row number
---@param col number
---@return boolean
local function block_contains_position(block, row, col)
  if row < block.line or row > block.end_line then
    return false
  end
  if row == block.line and col < block.start_col then
    return false
  end
  if row == block.end_line and col > block.end_col then
    return false
  end
  return true
end

---@param bufnr number
---@param cursor integer[]
---@return TfDocsContext|nil
local function get_context_fallback(bufnr, cursor)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local structure = hcl.scan_structure(lines)
  local row = cursor[1]
  local col = cursor[2]

  for _, block in ipairs(structure.blocks) do
    if block_contains_position(block, row, col) then
      local anchor = anchor_from_structure(structure, block, row, col)
      if block.kind == "module" then
        return {
          kind = "module",
          type = nil,
          module_source = block.module_source,
          module_source_reason = block.module_source_reason,
          anchor_candidate = anchor,
        }
      end
      return {
        kind = block.kind,
        type = block.type,
        provider_hint = block.provider_hint,
        anchor_candidate = anchor,
      }
    end
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

  local treesitter_status, treesitter_context = get_context_treesitter(bufnr, cursor)
  if treesitter_status == "ok" then
    set_cached_context(bufnr, cursor, treesitter_context)
    return treesitter_context
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 or row > line_count then
    set_cached_context(bufnr, cursor, nil)
    return nil
  end

  local context = get_context_fallback(bufnr, cursor)
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
---@field col number

---@param bufnr number
---@return TfDocsResource[]
function M.list_resources(bufnr)
  local results = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local structure = hcl.scan_structure(lines)

  for _, block in ipairs(structure.blocks) do
    results[#results + 1] = {
      kind = block.kind,
      type = block.type,
      name = block.name,
      line = block.line,
      col = block.start_col,
    }
  end

  return results
end

return M
