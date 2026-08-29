local M = {}

---@class TfDocsCacheEntry
---@field value any
---@field signature string
---@field meta any|nil

---@type table<string, TfDocsCacheEntry>
local required_cache = {}
---@type table<string, TfDocsCacheEntry>
local lockfile_cache = {}
-- Registry v2 lookups (session-lived, no TTL). Provider version metadata and
-- resolved doc slugs are stable for a given provider version, so they are kept
-- until an explicit clear (DirChanged / lockfile write / :TfDocClearCache).
---@type table<string, { versions: table<string, string>, latest: string|nil }>
local provider_versions_cache = {}
---@type table<string, string>
local slug_cache = {}

---@param module_dir string
---@param signature string
---@return table|nil
function M.get_required(module_dir, signature)
  local entry = required_cache[module_dir]
  if entry and entry.signature == signature then
    return entry.value
  end
  return nil
end

---@param module_dir string
---@param value table
---@param signature string
function M.set_required(module_dir, value, signature)
  required_cache[module_dir] = { value = value, signature = signature }
end

---@param workspace_root string
---@param signature string
---@return table|nil, table|nil
function M.get_lockfile(workspace_root, signature)
  local entry = lockfile_cache[workspace_root]
  if entry and entry.signature == signature then
    return entry.value, entry.meta
  end
  return nil, nil
end

---@param workspace_root string
---@param value table
---@param signature string
---@param meta table
function M.set_lockfile(workspace_root, value, signature, meta)
  lockfile_cache[workspace_root] = { value = value, signature = signature, meta = meta }
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

function M.clear()
  required_cache = {}
  lockfile_cache = {}
  provider_versions_cache = {}
  slug_cache = {}
end

return M
