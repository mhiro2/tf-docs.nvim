local cache = require("tf-docs.cache")
local hcl = require("tf-docs.hcl")
local utils = require("tf-docs.utils")

local M = {}

---@class TfDocsLockfileMeta
---@field version_missing boolean|nil
---@field version_multiple boolean|nil

---@type table<string, table<string, TfDocsLockfileMeta>>
local meta_by_root = {}

local function normalize_source(source)
  return source:gsub("^registry%.terraform%.io/", "")
end

---@param text string
---@return table<string, string>
function M.parse_text(text)
  local versions = {}
  local meta = {}

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
    if t.kind == "ident" and t.value == "provider" then
      local label = peek(1)
      local open = peek(2)
      if label and label.kind == "string" and open and open.kind == "symbol" and open.value == "{" then
        local source = normalize_source(label.value)

        i = i + 3
        local depth = 1
        local found_versions = {}

        while i <= n and depth > 0 do
          local cur = tokens[i]
          if cur.kind == "symbol" and cur.value == "{" then
            depth = depth + 1
            i = i + 1
          elseif cur.kind == "symbol" and cur.value == "}" then
            depth = depth - 1
            i = i + 1
          elseif depth == 1 and cur.kind == "ident" and cur.value == "version" then
            local eq = peek(1)
            local val = peek(2)
            if eq and eq.kind == "symbol" and eq.value == "=" and val and val.kind == "string" then
              found_versions[#found_versions + 1] = val.value
              i = i + 3
            else
              i = i + 1
            end
          else
            i = i + 1
          end
        end

        if #found_versions == 1 then
          versions[source] = found_versions[1]
        elseif #found_versions == 0 then
          meta[source] = meta[source] or {}
          meta[source].version_missing = true
        else
          versions[source] = found_versions[1]
          meta[source] = meta[source] or {}
          meta[source].version_multiple = true
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  return versions, meta
end

---@param root string|nil
---@return table<string, string>
function M.resolve(root)
  if not root then
    return {}
  end

  local cached = cache.get_lockfile(root)
  if cached then
    return cached
  end

  local path = vim.fs.joinpath(root, ".terraform.lock.hcl")
  local content = utils.read_file(path)
  if not content then
    cache.set_lockfile(root, {})
    meta_by_root[root] = {}
    return {}
  end

  local parsed, meta = M.parse_text(content)
  cache.set_lockfile(root, parsed)
  meta_by_root[root] = meta or {}
  return parsed
end

---@param root string|nil
---@return table<string, TfDocsLockfileMeta>
function M.get_meta(root)
  if not root then
    return {}
  end
  return meta_by_root[root] or {}
end

function M.clear_meta()
  meta_by_root = {}
end

---@param versions table<string, string>
---@param provider string
---@return string|nil
function M.find_source_by_name(versions, provider)
  for source, _ in pairs(versions) do
    local name = source:match("/([^/]+)$")
    if name == provider then
      return source
    end
  end
  return nil
end

return M
