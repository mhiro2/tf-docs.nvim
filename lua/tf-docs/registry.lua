-- Terraform Registry v2 API client.
--
-- Why this exists: the registry's doc-page slug is NOT a deterministic
-- transformation of the resource/data type. It is literally the filename the
-- provider authors chose. Most hashicorp/google resources drop the provider
-- prefix (google_compute_instance -> "compute_instance"), but some keep it
-- (google_service_account -> "google_service_account"), and the same name can
-- differ between resource and data source. The heuristic in url.lua (strip the
-- prefix) is therefore wrong for those.
--
-- This module asks the registry for the real slug. Resolution is async and is
-- raced against a timeout: on a warm cache the correct URL is returned
-- instantly; on a cold cache, if the API does not answer within
-- `registry_timeout_ms`, we fall back to the heuristic URL so the editor never
-- stalls. Either way the (network) result populates the cache for next time.

local cache = require("tf-docs.cache")
local config = require("tf-docs.config")
local url = require("tf-docs.url")

local M = {}

local API_BASE = "https://registry.terraform.io/v2"

---@type table<string, string>
local CATEGORY = { resource = "resources", data = "data-sources" }

-- Public-registry provider address ("namespace/name"). Public registry
-- namespaces and types are [A-Za-z0-9-] only, so we restrict to that: it keeps
-- HCL-derived strings from injecting extra path/query segments into the API URL
-- and, by excluding "." and "/", rules out "."/".." dot-segments that curl or
-- upstream infrastructure might path-normalize. (vim.system bypasses the shell,
-- so this is hardening, not a fix for command injection.)
local SOURCE_PATTERN = "^[%w-]+/[%w-]+$"

---Percent-encode a query value (RFC 3986 unreserved set kept verbatim).
---@param s string
---@return string
function M._encode_query(s)
  return (s:gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---@param v string
---@return integer[]
local function parse_semver(v)
  local core = v:match("^[^%-+]+") or v
  local parts = {}
  for n in core:gmatch("%d+") do
    parts[#parts + 1] = tonumber(n)
  end
  return parts
end

---@param a string
---@param b string
---@return boolean # true if a is a newer version than b
function M._semver_gt(a, b)
  local pa, pb = parse_semver(a), parse_semver(b)
  local n = math.max(#pa, #pb)
  for i = 1, n do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x > y
    end
  end
  -- Equal cores: prefer a stable release over a pre-release (e.g. 1.0.0 > 1.0.0-rc1).
  local a_pre = a:find("%-") ~= nil
  local b_pre = b:find("%-") ~= nil
  if a_pre ~= b_pre then
    return b_pre
  end
  return false
end

---HTTP GET that returns the decoded JSON body via `cb(table|nil)`. Overridable
---in tests. The default implementation shells out to curl through vim.system
---and delivers the callback on the main loop (vim.schedule), so downstream
---callers may freely use vim.* APIs.
---@param api string
---@param timeout_sec number
---@param cb fun(data: table|nil)
function M._http_get_json(api, timeout_sec, cb)
  if vim.fn.executable("curl") ~= 1 then
    cb(nil)
    return
  end
  local ok = pcall(function()
    vim.system({ "curl", "-sfL", "--max-time", tostring(timeout_sec), api }, { text = true }, function(res)
      local data = nil
      if res.code == 0 and type(res.stdout) == "string" and res.stdout ~= "" then
        local decoded_ok, decoded = pcall(vim.json.decode, res.stdout)
        if decoded_ok and type(decoded) == "table" then
          data = decoded
        end
      end
      vim.schedule(function()
        cb(data)
      end)
    end)
  end)
  if not ok then
    cb(nil)
  end
end

---Resolve a provider version string to its registry numeric version id.
---For "latest", returns the id of the newest known version.
---@param source string "namespace/name"
---@param version string
---@param timeout_sec number
---@param cb fun(version_id: string|nil)
local function resolve_version_id(source, version, timeout_sec, cb)
  local cached = cache.get_provider_versions(source)
  if cached then
    cb(version == "latest" and cached.latest or cached.versions[version])
    return
  end

  local api = API_BASE .. "/providers/" .. source .. "?include=provider-versions"
  M._http_get_json(api, timeout_sec, function(data)
    if not data or type(data.included) ~= "table" then
      cb(nil)
      return
    end

    local versions = {}
    local latest_id, latest_ver = nil, nil
    for _, item in ipairs(data.included) do
      if item.type == "provider-versions" and item.attributes and item.attributes.version and item.id then
        local ver = item.attributes.version
        versions[ver] = item.id
        if not latest_ver or M._semver_gt(ver, latest_ver) then
          latest_ver, latest_id = ver, item.id
        end
      end
    end

    cache.set_provider_versions(source, { versions = versions, latest = latest_id })
    cb(version == "latest" and latest_id or versions[version])
  end)
end

---Find the first candidate slug that actually exists as a doc page.
---@param version_id string
---@param category string
---@param candidates string[]
---@param timeout_sec number
---@param cb fun(slug: string|nil)
local function resolve_slug(version_id, category, candidates, timeout_sec, cb)
  local i = 0
  local function try_next()
    i = i + 1
    local cand = candidates[i]
    if not cand then
      cb(nil)
      return
    end
    local api = API_BASE
      .. "/provider-docs?filter%5Bprovider-version%5D="
      .. version_id
      .. "&filter%5Bcategory%5D="
      .. category
      .. "&filter%5Bslug%5D="
      .. M._encode_query(cand)
      .. "&page%5Bsize%5D=1"
    M._http_get_json(api, timeout_sec, function(data)
      local entry = data and type(data.data) == "table" and data.data[1] or nil
      if entry and entry.attributes and entry.attributes.slug then
        cb(entry.attributes.slug)
      else
        try_next()
      end
    end)
  end
  try_next()
end

---Extract the slug currently encoded in a heuristic docs URL.
---@param fallback_url string
---@param category string
---@return string|nil
function M._slug_from_url(fallback_url, category)
  local marker = "/docs/" .. category .. "/"
  local s = fallback_url:find(marker, 1, true)
  if not s then
    return nil
  end
  local rest = fallback_url:sub(s + #marker)
  return rest:match("^([^#?]+)")
end

---Build the candidate slug list (heuristic slug first, then the full type name),
---deduplicated and order-preserving.
---@param fallback_url string
---@param category string
---@param type_name string
---@return string[]
function M._candidates(fallback_url, category, type_name)
  local heuristic = M._slug_from_url(fallback_url, category)
  local out, seen = {}, {}
  for _, c in ipairs({ heuristic, type_name }) do
    if c and c ~= "" and not seen[c] then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out
end

---Stable cache key for a resolved slug.
---@param source string
---@param version string
---@param category string
---@param type_name string
---@return string
function M._cache_key(source, version, category, type_name)
  return table.concat({ source, version, category, type_name }, "\0")
end

---Rebuild a docs URL with a resolved slug, preserving any anchor present in the
---heuristic URL.
---@param source string
---@param version string
---@param category string
---@param slug string
---@param fallback_url string
---@return string
local function build_url(source, version, category, slug, fallback_url)
  local u = url.docs_url(source, version, category, slug)
  local anchor = fallback_url:match("#(.+)$")
  if anchor then
    u = u .. "#" .. anchor
  end
  return u
end

---Whether registry lookup applies to a trace, and the fields it needs.
---Only the public Terraform Registry (source shaped as "namespace/name") is
---supported; custom hosts / private registries are skipped.
---@param trace TfDocsTrace|nil
---@param cfg TfDocsConfig
---@return string? category, string? source, string? version, string? type_name
local function applicable(trace, cfg)
  local category = trace and trace.kind and CATEGORY[trace.kind]
  local source = trace and trace.provider_source
  local version = trace and trace.provider_version
  local type_name = trace and trace.type
  if
    not cfg.enable_registry_lookup
    or not category
    or not source
    or not version
    or not type_name
    or not source:match(SOURCE_PATTERN)
  then
    return nil
  end
  return category, source, version, type_name
end

---Synchronous, network-free counterpart of `resolve_url`: returns the
---registry-corrected URL when its slug is already cached, otherwise the
---heuristic `fallback_url` unchanged. Used by the synchronous entry points
---(`resolve`/`peek`/`debug`) so they reflect a warm cache too.
---@param trace TfDocsTrace
---@param fallback_url string
---@return string
function M.resolve_cached_url(trace, fallback_url)
  local cfg = config.get()
  local category, source, version, type_name = applicable(trace, cfg)
  if not category then
    return fallback_url
  end
  local cached = cache.get_slug(M._cache_key(source, version, category, type_name))
  if cached then
    return build_url(source, version, category, cached, fallback_url)
  end
  return fallback_url
end

---Resolve the best docs URL for a trace and deliver it via `on_done(url)`.
---Guarantees exactly one `on_done` call. Behaviour:
---  * feature disabled / non-applicable / private registry -> fallback (sync)
---  * warm slug cache -> corrected URL (sync)
---  * cold cache -> async; correct URL if the API answers within the timeout,
---    otherwise the heuristic fallback (the API result still backfills the cache)
---@param trace TfDocsTrace
---@param fallback_url string
---@param on_done fun(url: string)
function M.resolve_url(trace, fallback_url, on_done)
  local cfg = config.get()
  local category, source, version, type_name = applicable(trace, cfg)
  if not category then
    on_done(fallback_url)
    return
  end

  local candidates = M._candidates(fallback_url, category, type_name)
  if #candidates == 0 then
    on_done(fallback_url)
    return
  end

  local cache_key = M._cache_key(source, version, category, type_name)
  local cached = cache.get_slug(cache_key)
  if cached then
    on_done(build_url(source, version, category, cached, fallback_url))
    return
  end

  local timeout_ms = cfg.registry_timeout_ms
  local timeout_sec = math.max(2, math.ceil(timeout_ms / 1000) + 1)
  local done = false
  local timer = vim.uv.new_timer()

  local function finish(final_url)
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    on_done(final_url)
  end

  -- The libuv timer is a best-effort early fallback. If it cannot be created or
  -- started, the async chain below still guarantees exactly one finish(): every
  -- _http_get_json path invokes its callback (curl's --max-time bounds it), so
  -- on_done is never lost -- it just isn't bounded by registry_timeout_ms.
  if timer then
    local ok = pcall(function()
      timer:start(timeout_ms, 0, function()
        vim.schedule(function()
          finish(fallback_url)
        end)
      end)
    end)
    if not ok then
      pcall(function()
        timer:close()
      end)
      timer = nil
    end
  end

  resolve_version_id(source, version, timeout_sec, function(version_id)
    if not version_id then
      finish(fallback_url)
      return
    end
    resolve_slug(version_id, category, candidates, timeout_sec, function(slug)
      if slug then
        cache.set_slug(cache_key, slug)
        finish(build_url(source, version, category, slug, fallback_url))
      else
        -- Queries succeeded but no candidate matched; nothing better than the
        -- heuristic. Leave the slug uncached so a transient miss can retry.
        finish(fallback_url)
      end
    end)
  end)
end

return M
