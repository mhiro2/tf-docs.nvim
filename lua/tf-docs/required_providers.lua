local cache = require("tf-docs.cache")
local hcl = require("tf-docs.hcl")
local utils = require("tf-docs.utils")

local M = {}

---@param source string
---@return string
local function normalize_source(source)
  return source:gsub("^registry%.terraform%.io/", "")
end

---@param text string
---@return table<string, string>, table<string, boolean>
function M.parse_text(text)
  local result = {}
  local declared = {}
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
            -- alias = { source = "hashicorp/aws" ... }
            local alias = cur.value
            local eq = peek(1)
            if eq and eq.kind == "symbol" and eq.value == "=" then
              declared[alias] = true
              result[alias] = nil
              local rhs = peek(2)
              if rhs and rhs.kind == "string" then
                -- Legacy string values are version constraints, not provider
                -- source addresses.
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
                      result[alias] = normalize_source(val.value)
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

  return result, declared
end

---@param result table<string, string>
---@param declared table<string, boolean>
---@param body any
local function parse_json_terraform_body(result, declared, body)
  if type(body) ~= "table" or type(body.required_providers) ~= "table" then
    return
  end
  for alias, requirement in pairs(body.required_providers) do
    if type(alias) == "string" then
      declared[alias] = true
      result[alias] = nil
      if type(requirement) == "table" and type(requirement.source) == "string" then
        result[alias] = normalize_source(requirement.source)
      end
    end
  end
end

---@param text string
---@return table<string, string>, table<string, boolean>
function M.parse_json(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" or type(decoded.terraform) ~= "table" then
    return {}, {}
  end

  local result = {}
  local declared = {}
  if vim.islist(decoded.terraform) then
    for _, body in ipairs(decoded.terraform) do
      parse_json_terraform_body(result, declared, body)
    end
  else
    parse_json_terraform_body(result, declared, decoded.terraform)
  end
  return result, declared
end

---@class TfDocsSourceSnapshot
---@field path string
---@field name string
---@field format "hcl"|"json"
---@field override boolean
---@field signature string

---@param name string
---@return "hcl"|"json"|nil
local function terraform_format(name)
  if name:match("%.tf%.json$") then
    return "json"
  end
  if name:match("%.tf$") then
    return "hcl"
  end
  return nil
end

---@param name string
---@return boolean
local function is_ignored_file(name)
  return name:sub(1, 1) == "." or name:sub(-1) == "~" or (name:sub(1, 1) == "#" and name:sub(-1) == "#")
end

---@param name string
---@return boolean
local function is_override(name)
  return name == "override.tf"
    or name == "override.tf.json"
    or name:match("_override%.tf$") ~= nil
    or name:match("_override%.tf%.json$") ~= nil
end

---@param module_dir string
---@return TfDocsSourceSnapshot[]
local function source_snapshots(module_dir)
  local by_path = {}

  ---@param path string
  ---@param name string
  local function add(path, name)
    if is_ignored_file(name) then
      return
    end
    local format = terraform_format(name)
    if not format then
      return
    end
    path = vim.fs.normalize(path)
    by_path[path] = {
      path = path,
      name = name,
      format = format,
      override = is_override(name),
      signature = utils.file_signature(path),
    }
  end

  local handle = vim.uv.fs_scandir(module_dir)
  if handle then
    while true do
      local name, entry_type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if entry_type == "file" or entry_type == "link" then
        add(vim.fs.joinpath(module_dir, name), name)
      end
    end
  end

  for _, path in ipairs(utils.modified_buffer_paths(module_dir)) do
    add(path, vim.fs.basename(path))
  end

  local snapshots = {}
  for _, snapshot in pairs(by_path) do
    snapshots[#snapshots + 1] = snapshot
  end
  table.sort(snapshots, function(a, b)
    if a.override ~= b.override then
      return not a.override
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.path < b.path
  end)
  return snapshots
end

---@param snapshots TfDocsSourceSnapshot[]
---@return string
local function snapshots_signature(snapshots)
  local parts = {}
  for _, snapshot in ipairs(snapshots) do
    parts[#parts + 1] = snapshot.path
    parts[#parts + 1] = snapshot.format
    parts[#parts + 1] = snapshot.signature
  end
  return table.concat(parts, "\0")
end

---@param module_dir string|nil
---@return table<string, string>
function M.resolve(module_dir)
  if not module_dir then
    return {}
  end
  module_dir = utils.canonical_path(module_dir)

  local snapshots = source_snapshots(module_dir)

  local cached = cache.get_required(module_dir, snapshots_signature(snapshots))
  if cached then
    return cached
  end

  local merged = {}
  for _, snapshot in ipairs(snapshots) do
    local content, signature = utils.read_source(snapshot.path)
    snapshot.signature = signature
    if content then
      local parsed, declared
      if snapshot.format == "json" then
        parsed, declared = M.parse_json(content)
      else
        parsed, declared = M.parse_text(content)
      end
      for alias, _ in pairs(declared) do
        -- A declaration without source uses Terraform's implied provider
        -- address and must not fall back to a similarly named lockfile entry.
        merged[alias] = "hashicorp/" .. alias
      end
      for alias, source in pairs(parsed) do
        merged[alias] = source
      end
    end
  end

  cache.set_required(module_dir, merged, snapshots_signature(snapshots))
  return merged
end

return M
