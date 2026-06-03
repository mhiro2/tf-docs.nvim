local M = {}

---@class TfDocsCacheEntry
---@field value any
---@field updated number

---@type table<string, TfDocsCacheEntry>
local required_cache = {}
---@type table<string, TfDocsCacheEntry>
local lockfile_cache = {}
---@type table<number, string>
local root_cache = {}
-- Registry v2 lookups (session-lived, no TTL). Provider version metadata and
-- resolved doc slugs are stable for a given provider version, so they are kept
-- until an explicit clear (DirChanged / lockfile write / :TfDocClearCache).
---@type table<string, { versions: table<string, string>, latest: string|nil }>
local provider_versions_cache = {}
---@type table<string, string>
local slug_cache = {}

local function is_fresh(entry, ttl)
  if not entry then
    return false
  end
  if not ttl or ttl <= 0 then
    return true
  end
  return (os.time() - entry.updated) <= ttl
end

---@param root string
---@param ttl number|nil
---@return table|nil
function M.get_required(root, ttl)
  local entry = required_cache[root]
  if is_fresh(entry, ttl) then
    return entry.value
  end
  return nil
end

---@param root string
---@param value table
function M.set_required(root, value)
  required_cache[root] = { value = value, updated = os.time() }
end

---@param root string
---@param ttl number|nil
---@return table|nil
function M.get_lockfile(root, ttl)
  local entry = lockfile_cache[root]
  if is_fresh(entry, ttl) then
    return entry.value
  end
  return nil
end

---@param root string
---@param value table
function M.set_lockfile(root, value)
  lockfile_cache[root] = { value = value, updated = os.time() }
end

---@param bufnr number
---@return string|nil
function M.get_root(bufnr)
  return root_cache[bufnr]
end

---@param bufnr number
---@param root string
function M.set_root(bufnr, root)
  root_cache[bufnr] = root
end

---Provider version metadata for a registry source ("namespace/name").
---@param source string
---@return { versions: table<string, string>, latest: string|nil }|nil
function M.get_provider_versions(source)
  return provider_versions_cache[source]
end

---@param source string
---@param value { versions: table<string, string>, latest: string|nil }
function M.set_provider_versions(source, value)
  provider_versions_cache[source] = value
end

---Resolved Terraform Registry doc slug for a (source, version, category, type) key.
---@param key string
---@return string|nil
function M.get_slug(key)
  return slug_cache[key]
end

---@param key string
---@param slug string
function M.set_slug(key, slug)
  slug_cache[key] = slug
end

---@param bufnr number
function M.clear_buf(bufnr)
  root_cache[bufnr] = nil
end

function M.clear()
  required_cache = {}
  lockfile_cache = {}
  root_cache = {}
  provider_versions_cache = {}
  slug_cache = {}
end

return M
