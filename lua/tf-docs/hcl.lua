local M = {}

---@class TfDocsHclToken
---@field kind "ident"|"string"|"symbol"
---@field value string

local function is_ident_char(ch)
  return ch:match("[%w_-]") ~= nil
end

---@param text string
---@return TfDocsHclToken[]
function M.tokenize(text)
  ---@type TfDocsHclToken[]
  local out = {}

  local i = 1
  local n = #text
  local in_block_comment = false

  local function peek(offset)
    offset = offset or 0
    local pos = i + offset
    if pos < 1 or pos > n then
      return nil
    end
    return text:sub(pos, pos)
  end

  local function add(kind, value)
    out[#out + 1] = { kind = kind, value = value }
  end

  while i <= n do
    local ch = peek(0)

    if in_block_comment then
      if ch == "*" and peek(1) == "/" then
        in_block_comment = false
        i = i + 2
      else
        i = i + 1
      end
    elseif ch == "/" and peek(1) == "*" then
      in_block_comment = true
      i = i + 2
    elseif ch == "#" then
      -- Line comment
      while i <= n and peek(0) ~= "\n" do
        i = i + 1
      end
    elseif ch == "/" and peek(1) == "/" then
      -- Line comment
      i = i + 2
      while i <= n and peek(0) ~= "\n" do
        i = i + 1
      end
    elseif ch == '"' then
      -- String literal (double quotes)
      i = i + 1
      local buf = {}
      while i <= n do
        local c = peek(0)
        if c == "\\" then
          local nextc = peek(1)
          if nextc then
            buf[#buf + 1] = nextc
            i = i + 2
          else
            i = i + 1
          end
        elseif c == '"' then
          i = i + 1
          break
        else
          buf[#buf + 1] = c
          i = i + 1
        end
      end
      add("string", table.concat(buf, ""))
    elseif ch:match("%s") then
      i = i + 1
    elseif is_ident_char(ch) then
      local start = i
      while i <= n and is_ident_char(peek(0)) do
        i = i + 1
      end
      add("ident", text:sub(start, i - 1))
    else
      add("symbol", ch)
      i = i + 1
    end
  end

  return out
end

return M
