local M = {}
local kinds = require("tf-docs.kinds")

---@class TfDocsHclToken
---@field kind "ident"|"string"|"symbol"
---@field value string

local scan_structural_tokens

---@param text string
---@return TfDocsHclToken[]
function M.tokenize(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local structural_tokens = scan_structural_tokens(lines)
  local tokens = {} ---@type TfDocsHclToken[]
  for _, token in ipairs(structural_tokens) do
    if token.kind == "ident" or token.kind == "symbol" then
      tokens[#tokens + 1] = { kind = token.kind, value = token.value or "" }
    elseif token.kind == "string" and token.static then
      tokens[#tokens + 1] = { kind = "string", value = token.value or "" }
    end
  end

  return tokens
end

---@param raw string
---@return string|nil
function M.decode_quoted_literal(raw)
  if #raw < 2 or raw:sub(1, 1) ~= '"' or raw:sub(-1) ~= '"' then
    return nil
  end

  local out = {}
  local i = 2
  local last = #raw - 1
  while i <= last do
    local ch = raw:sub(i, i)
    local next_ch = raw:sub(i + 1, i + 1)
    local third_ch = raw:sub(i + 2, i + 2)

    if ch == "\\" then
      local escapes = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
      local decoded = escapes[next_ch]
      if decoded then
        out[#out + 1] = decoded
        i = i + 2
      elseif next_ch == "u" or next_ch == "U" then
        local digit_count = next_ch == "u" and 4 or 8
        local digits = raw:sub(i + 2, i + 1 + digit_count)
        local codepoint = #digits == digit_count and digits:match("^%x+$") and tonumber(digits, 16) or nil
        if not codepoint or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff) then
          return nil
        end
        local ok_char, char = pcall(vim.fn.nr2char, codepoint)
        if not ok_char or not char or char == "" then
          return nil
        end
        out[#out + 1] = char
        i = i + digit_count + 2
      else
        return nil
      end
    elseif (ch == "$" or ch == "%") and next_ch == ch and third_ch == "{" then
      out[#out + 1] = ch .. "{"
      i = i + 3
    elseif (ch == "$" or ch == "%") and next_ch == "{" then
      return nil
    elseif ch == '"' or ch == "\n" or ch == "\r" then
      return nil
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end

  return table.concat(out)
end

---@class TfDocsHclStructuralToken
---@field kind "ident"|"string"|"symbol"|"heredoc"
---@field value string|nil
---@field line number
---@field col number
---@field line_first boolean
---@field static boolean|nil

---@class TfDocsHclStructuralBlock
---@field kind TfDocsBlockKind
---@field type string|nil
---@field name string
---@field line number
---@field start_col number
---@field end_line number
---@field end_col number
---@field open_token number
---@field close_token number
---@field module_source string|nil
---@field module_source_reason string|nil
---@field provider_hint string|nil

---@class TfDocsHclStructure
---@field tokens TfDocsHclStructuralToken[]
---@field line_tokens table<number, TfDocsHclStructuralToken[]>
---@field blocks TfDocsHclStructuralBlock[]

---@param ch string
---@return boolean
local function is_structural_ident_start(ch)
  return ch:match("[%a_]") ~= nil
end

---@param ch string
---@return boolean
local function is_structural_ident_char(ch)
  return ch:match("[%w_%-]") ~= nil
end

---@param tokens TfDocsHclStructuralToken[]
---@param index number
---@return { kind: TfDocsBlockKind, type: string|nil, name: string, open_token: number }|nil
local function structural_header_at(tokens, index)
  local keyword = tokens[index]
  if not keyword or keyword.kind ~= "ident" then
    return nil
  end

  local previous = tokens[index - 1]
  local follows_one_line_block = previous and previous.kind == "symbol" and previous.value == "}"
  if not keyword.line_first and not follows_one_line_block then
    return nil
  end

  local first_label = tokens[index + 1]
  if not first_label or first_label.kind ~= "string" or not first_label.static then
    return nil
  end

  if keyword.value == "module" then
    local open = tokens[index + 2]
    if open and open.kind == "symbol" and open.value == "{" then
      return { kind = "module", type = nil, name = first_label.value or "", open_token = index + 2 }
    end
    return nil
  end

  if not kinds.is_provider_backed(keyword.value) then
    return nil
  end

  local second_label = tokens[index + 2]
  local open = tokens[index + 3]
  if
    second_label
    and second_label.kind == "string"
    and second_label.static
    and open
    and open.kind == "symbol"
    and open.value == "{"
  then
    return {
      kind = keyword.value,
      type = first_label.value,
      name = second_label.value or "",
      open_token = index + 3,
    }
  end

  return nil
end

---@param token TfDocsHclStructuralToken|nil
---@param value string
---@return boolean
local function is_symbol(token, value)
  return token ~= nil and token.kind == "symbol" and token.value == value
end

---@param tokens TfDocsHclStructuralToken[]
---@param index number
---@param close_token number
---@return boolean
local function starts_body_item(tokens, index, close_token)
  local token = tokens[index]
  if not token or token.kind ~= "ident" then
    return false
  end
  if is_symbol(tokens[index + 1], "=") then
    return true
  end

  local cursor = index + 1
  while cursor < close_token do
    local candidate = tokens[cursor]
    if is_symbol(candidate, "{") then
      return true
    end
    if not candidate or (candidate.kind ~= "ident" and candidate.kind ~= "string") then
      return false
    end
    cursor = cursor + 1
  end
  return false
end

---@param tokens TfDocsHclStructuralToken[]
---@param index number
---@param close_token number
---@return boolean
local function expression_ends_at(tokens, index, close_token)
  local next_index = index + 1
  return next_index >= close_token or starts_body_item(tokens, next_index, close_token)
end

---@param tokens TfDocsHclStructuralToken[]
---@param index number
---@param close_token number
---@return string|nil
local function provider_reference_at(tokens, index, close_token)
  local provider = tokens[index]
  if not provider or provider.kind ~= "ident" then
    return nil
  end

  local expression_end = index
  if is_symbol(tokens[index + 1], ".") then
    local alias = tokens[index + 2]
    if not alias or alias.kind ~= "ident" then
      return nil
    end
    expression_end = index + 2
  end

  if not expression_ends_at(tokens, expression_end, close_token) then
    return nil
  end
  return provider.value
end

---@param block TfDocsHclStructuralBlock
---@param tokens TfDocsHclStructuralToken[]
local function populate_structural_attributes(block, tokens)
  local curly_depth = 0
  local square_depth = 0
  local paren_depth = 0
  local index = block.open_token + 1

  while index < block.close_token do
    local token = tokens[index]
    local at_body_level = curly_depth == 0 and square_depth == 0 and paren_depth == 0
    local next_token = tokens[index + 1]

    if
      at_body_level
      and token.kind == "ident"
      and next_token
      and next_token.kind == "symbol"
      and next_token.value == "="
    then
      local value = tokens[index + 2]
      if block.kind == "module" and token.value == "source" and block.module_source_reason == nil then
        local expression_is_literal = value
          and value.kind == "string"
          and value.static
          and expression_ends_at(tokens, index + 2, block.close_token)
        if expression_is_literal then
          block.module_source = value.value
        else
          block.module_source_reason = "module-source-expression"
        end
      elseif block.kind ~= "module" and token.value == "provider" and block.provider_hint == nil then
        block.provider_hint = provider_reference_at(tokens, index + 2, block.close_token)
      end
    end

    if token.kind == "symbol" then
      if token.value == "{" then
        curly_depth = curly_depth + 1
      elseif token.value == "}" then
        curly_depth = math.max(0, curly_depth - 1)
      elseif token.value == "[" then
        square_depth = square_depth + 1
      elseif token.value == "]" then
        square_depth = math.max(0, square_depth - 1)
      elseif token.value == "(" then
        paren_depth = paren_depth + 1
      elseif token.value == ")" then
        paren_depth = math.max(0, paren_depth - 1)
      end
    end

    index = index + 1
  end

  if block.kind == "module" and block.module_source == nil and block.module_source_reason == nil then
    block.module_source_reason = "module-source-missing"
  end
end

---@param lines string[]
---@return TfDocsHclStructuralToken[], table<number, TfDocsHclStructuralToken[]>
scan_structural_tokens = function(lines)
  local tokens = {} ---@type TfDocsHclStructuralToken[]
  local line_tokens = {} ---@type table<number, TfDocsHclStructuralToken[]>
  local in_block_comment = false
  local heredoc = nil ---@type { delimiter: string, allow_indent: boolean }|nil
  local quote = nil ---@type { parts: string[], stack: table[], line: number, col: number, line_first: boolean }|nil

  local function add_token(token)
    tokens[#tokens + 1] = token
    line_tokens[token.line] = line_tokens[token.line] or {}
    line_tokens[token.line][#line_tokens[token.line] + 1] = token
  end

  for line_number, line in ipairs(lines) do
    line_tokens[line_number] = line_tokens[line_number] or {}
    local seen_code = false

    if heredoc then
      local delimiter_line = line:gsub("\r$", "")
      delimiter_line = heredoc.allow_indent and delimiter_line:gsub("^[ \t]*", "") or delimiter_line
      if delimiter_line == heredoc.delimiter then
        heredoc = nil
      end
    else
      local index = 1
      local length = #line

      while index <= length do
        local ch = line:sub(index, index)
        local next_ch = line:sub(index + 1, index + 1)

        if quote then
          local top = quote.stack[#quote.stack]
          if top.mode == "block_comment" then
            if ch == "*" and next_ch == "/" then
              quote.parts[#quote.parts + 1] = "*/"
              quote.stack[#quote.stack] = nil
              index = index + 2
            else
              quote.parts[#quote.parts + 1] = ch
              index = index + 1
            end
          elseif top.mode == "interpolation" then
            if ch == '"' then
              quote.parts[#quote.parts + 1] = ch
              quote.stack[#quote.stack + 1] = { mode = "quoted" }
              index = index + 1
            elseif ch == "/" and next_ch == "*" then
              quote.parts[#quote.parts + 1] = "/*"
              quote.stack[#quote.stack + 1] = { mode = "block_comment" }
              index = index + 2
            elseif ch == "#" or (ch == "/" and next_ch == "/") then
              quote.parts[#quote.parts + 1] = line:sub(index)
              index = length + 1
            elseif ch == "{" then
              top.depth = top.depth + 1
              quote.parts[#quote.parts + 1] = ch
              index = index + 1
            elseif ch == "}" then
              top.depth = top.depth - 1
              quote.parts[#quote.parts + 1] = ch
              index = index + 1
              if top.depth == 0 then
                quote.stack[#quote.stack] = nil
              end
            else
              quote.parts[#quote.parts + 1] = ch
              index = index + 1
            end
          elseif ch == "\\" then
            quote.parts[#quote.parts + 1] = line:sub(index, math.min(index + 1, length))
            index = index + 2
          elseif (ch == "$" or ch == "%") and next_ch == ch and line:sub(index + 2, index + 2) == "{" then
            quote.parts[#quote.parts + 1] = line:sub(index, index + 2)
            index = index + 3
          elseif (ch == "$" or ch == "%") and next_ch == "{" then
            quote.parts[#quote.parts + 1] = ch .. next_ch
            quote.stack[#quote.stack + 1] = { mode = "interpolation", depth = 1 }
            index = index + 2
          elseif ch == '"' then
            quote.parts[#quote.parts + 1] = ch
            quote.stack[#quote.stack] = nil
            index = index + 1
            if #quote.stack == 0 then
              local raw = table.concat(quote.parts)
              local value = M.decode_quoted_literal(raw)
              add_token({
                kind = "string",
                value = value,
                line = quote.line,
                col = quote.col,
                line_first = quote.line_first,
                static = value ~= nil,
              })
              quote = nil
            end
          else
            quote.parts[#quote.parts + 1] = ch
            index = index + 1
          end
        elseif in_block_comment then
          if ch == "*" and next_ch == "/" then
            in_block_comment = false
            index = index + 2
          else
            index = index + 1
          end
        elseif ch == "/" and next_ch == "*" then
          in_block_comment = true
          index = index + 2
        elseif ch == "#" or (ch == "/" and next_ch == "/") then
          break
        elseif ch == '"' then
          quote = {
            parts = { ch },
            stack = { { mode = "quoted" } },
            line = line_number,
            col = index - 1,
            line_first = not seen_code,
          }
          seen_code = true
          index = index + 1
        elseif ch == "<" and next_ch == "<" then
          local operator, marker = line:sub(index):match("^(<<%-?)%s*([%a_][%w_%-]*)")
          if marker then
            add_token({
              kind = "heredoc",
              value = nil,
              line = line_number,
              col = index - 1,
              line_first = not seen_code,
            })
            seen_code = true
            heredoc = { delimiter = marker, allow_indent = operator == "<<-" }
            index = length + 1
          else
            add_token({
              kind = "symbol",
              value = ch,
              line = line_number,
              col = index - 1,
              line_first = not seen_code,
            })
            seen_code = true
            index = index + 1
          end
        elseif ch:match("%s") then
          index = index + 1
        elseif is_structural_ident_start(ch) then
          local start = index
          index = index + 1
          while index <= length and is_structural_ident_char(line:sub(index, index)) do
            index = index + 1
          end
          add_token({
            kind = "ident",
            value = line:sub(start, index - 1),
            line = line_number,
            col = start - 1,
            line_first = not seen_code,
          })
          seen_code = true
        else
          add_token({
            kind = "symbol",
            value = ch,
            line = line_number,
            col = index - 1,
            line_first = not seen_code,
          })
          seen_code = true
          index = index + 1
        end
      end
    end

    if quote then
      quote.parts[#quote.parts + 1] = "\n"
    end
  end

  return tokens, line_tokens
end

---@param lines string[]
---@return TfDocsHclStructure
function M.scan_structure(lines)
  local tokens, line_tokens = scan_structural_tokens(lines)

  local headers_by_open = {}
  local blocks = {} ---@type TfDocsHclStructuralBlock[]
  local depth = 0
  local active = nil ---@type TfDocsHclStructuralBlock|nil

  for index, token in ipairs(tokens) do
    if depth == 0 then
      local header = structural_header_at(tokens, index)
      if header then
        headers_by_open[header.open_token] = {
          kind = header.kind,
          type = header.type,
          name = header.name,
          line = token.line,
          start_col = token.col,
        }
      end
    end

    if token.kind == "symbol" and token.value == "{" then
      local header = headers_by_open[index]
      depth = depth + 1
      if header then
        active = {
          kind = header.kind,
          type = header.type,
          name = header.name,
          line = header.line,
          start_col = header.start_col,
          end_line = #lines,
          end_col = #(lines[#lines] or ""),
          open_token = index,
          close_token = #tokens + 1,
        }
        blocks[#blocks + 1] = active
      end
    elseif token.kind == "symbol" and token.value == "}" then
      if active and depth == 1 then
        active.end_line = token.line
        active.end_col = token.col
        active.close_token = index
        populate_structural_attributes(active, tokens)
        active = nil
      end
      depth = math.max(0, depth - 1)
    end
  end

  if active then
    populate_structural_attributes(active, tokens)
  end

  return { tokens = tokens, line_tokens = line_tokens, blocks = blocks }
end

return M
