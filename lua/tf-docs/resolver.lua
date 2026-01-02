local config = require("tf-docs.config")
local lockfile = require("tf-docs.lockfile")
local required_providers = require("tf-docs.required_providers")
local root = require("tf-docs.root")
local ts = require("tf-docs.ts")
local url = require("tf-docs.url")

local M = {}

---@class TfDocsTrace
---@field root string|nil
---@field kind string|nil
---@field type string|nil
---@field module_source string|nil
---@field provider string|nil
---@field provider_source string|nil
---@field provider_version string|nil
---@field anchor string|nil
---@field url string|nil
---@field reason string|nil

---@param type_name string
---@param overrides table<string, string>
---@return string|nil
local function infer_provider(type_name, provider_hint, overrides)
  local p = provider_hint
  if not p or p == "" then
    if not type_name then
      return nil
    end
    p = type_name:match("^([^_]+)_")
    if not p then
      return nil
    end
  end
  return overrides[p] or p
end

---@param source string
---@param allowlist string[]
---@return boolean
local function allow_anchor(source, allowlist)
  for _, item in ipairs(allowlist) do
    if item == source then
      return true
    end
  end
  return false
end

---@param bufnr number
---@param opts {context?: TfDocsContext, root?: string}|nil
---@return string|nil, TfDocsTrace
function M.resolve(bufnr, opts)
  local cfg = config.get()
  local trace = {}
  opts = opts or {}

  local root_dir = opts.root or root.get_root(bufnr, cfg)
  trace.root = root_dir

  local context = opts.context or ts.get_context(bufnr)
  if not context then
    trace.reason = "no-context"
    return nil, trace
  end

  trace.kind = context.kind
  trace.type = context.type
  trace.module_source = context.module_source
  trace.anchor = context.anchor_candidate

  if context.kind == "module" then
    if not cfg.enable_module_docs then
      trace.reason = "module-disabled"
      return nil, trace
    end

    local module_url = url.module_url(context.module_source or "")
    if not module_url then
      trace.reason = "module-source-unresolved"
      return nil, trace
    end

    trace.url = module_url
    return module_url, trace
  end

  local provider = infer_provider(context.type, context.provider_hint, cfg.provider_overrides)
  if not provider then
    trace.reason = "provider-unresolved"
    return nil, trace
  end
  trace.provider = provider

  local required = required_providers.resolve(root_dir, cfg)
  local versions = lockfile.resolve(root_dir)
  local lock_meta = lockfile.get_meta(root_dir)

  local source = required[provider]
  if not source then
    source = lockfile.find_source_by_name(versions, provider)
  end
  if not source then
    source = cfg.default_namespace .. "/" .. provider
  end
  trace.provider_source = source

  local version = versions[source] or cfg.default_version
  trace.provider_version = version

  local type_prefix = context.type and context.type:match("^([^_]+)_") or provider

  local meta = lock_meta[source]
  if meta then
    if meta.version_missing then
      trace.reason = trace.reason or "lockfile-version-missing"
    elseif meta.version_multiple then
      trace.reason = trace.reason or "lockfile-version-multiple"
    end
  end

  local base_url
  if context.kind == "resource" then
    base_url = url.resource_url(source, version, context.type, type_prefix)
  elseif context.kind == "data" then
    base_url = url.data_url(source, version, context.type, type_prefix)
  end

  if not base_url then
    trace.reason = "url-unresolved"
    return nil, trace
  end

  if cfg.enable_anchor and trace.anchor and allow_anchor(source, cfg.anchor_providers_allowlist) then
    base_url = url.with_anchor(base_url, trace.anchor)
  end

  trace.url = base_url
  return base_url, trace
end

return M
