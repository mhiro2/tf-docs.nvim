local cache = require("tf-docs.cache")
local hcl = require("tf-docs.hcl")
local utils = require("tf-docs.utils")

local M = {}

---@param text string
---@return table<string, string>
function M.parse_text(text)
  local result = {}
  local tokens = hcl.tokenize(text)

  local i = 1
  local n = #tokens

  local function peek(offset)
    local idx = i + (offset or 0)
    if idx < 1 or idx > n then
      return nil
    end
    return tokens[idx]
  end

  while i <= n do
    local t = tokens[i]
    if t.kind == "ident" and t.value == "required_providers" then
      local t1 = peek(1)
      if t1 and t1.kind == "symbol" and t1.value == "{" then
        -- Parse inside required_providers { ... }
        i = i + 2
        local depth = 1

        while i <= n and depth > 0 do
          local cur = tokens[i]
          if cur.kind == "symbol" and cur.value == "{" then
            depth = depth + 1
            i = i + 1
          elseif cur.kind == "symbol" and cur.value == "}" then
            depth = depth - 1
            i = i + 1
          elseif depth == 1 and cur.kind == "ident" then
            -- alias = "hashicorp/aws"
            -- alias = { source = "hashicorp/aws" ... }
            local alias = cur.value
            local eq = peek(1)
            if eq and eq.kind == "symbol" and eq.value == "=" then
              local rhs = peek(2)
              if rhs and rhs.kind == "string" then
                result[alias] = rhs.value
                i = i + 3
              elseif rhs and rhs.kind == "symbol" and rhs.value == "{" then
                -- Parse object, extract source at object-depth==1
                i = i + 3
                local obj_depth = 1
                while i <= n and obj_depth > 0 do
                  local tok = tokens[i]
                  if tok.kind == "symbol" and tok.value == "{" then
                    obj_depth = obj_depth + 1
                    i = i + 1
                  elseif tok.kind == "symbol" and tok.value == "}" then
                    obj_depth = obj_depth - 1
                    i = i + 1
                  elseif obj_depth == 1 and tok.kind == "ident" and tok.value == "source" then
                    local eq2 = peek(1)
                    local val = peek(2)
                    if eq2 and eq2.kind == "symbol" and eq2.value == "=" and val and val.kind == "string" then
                      result[alias] = val.value
                      i = i + 3
                    else
                      i = i + 1
                    end
                  else
                    i = i + 1
                  end
                end
              else
                i = i + 1
              end
            else
              i = i + 1
            end
          else
            i = i + 1
          end
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  return result
end

---@param root string|nil
---@param cfg TfDocsConfig
---@return table<string, string>
function M.resolve(root, cfg)
  if not root then
    return {}
  end

  local cached = cache.get_required(root)
  if cached then
    return cached
  end

  local merged = {}
  -- Merge priority: later files override earlier ones (based on cfg.required_providers_files order).
  for _, filename in ipairs(cfg.required_providers_files) do
    local path = vim.fs.joinpath(root, filename)
    local content = utils.read_file(path)
    if content then
      local parsed = M.parse_text(content)
      for alias, source in pairs(parsed) do
        merged[alias] = source
      end
    end
  end

  cache.set_required(root, merged)
  return merged
end

return M
