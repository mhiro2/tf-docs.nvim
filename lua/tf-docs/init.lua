local config = require("tf-docs.config")
local cache = require("tf-docs.cache")
local lockfile = require("tf-docs.lockfile")
local log = require("tf-docs.log")
local registry = require("tf-docs.registry")
local resolver = require("tf-docs.resolver")
local ui = require("tf-docs.ui")
local ts = require("tf-docs.ts")

local M = {}

local commands_created = false
local autocmd_group = "tf-docs.nvim"

local function clear_runtime_cache()
  cache.clear()
  lockfile.clear_meta()
  ts.clear_context_cache()
end

---@type table<string, string>
local unresolved_reason_messages = {
  ["no-context"] = "No terraform resource/data/module under cursor",
  ["module-disabled"] = "Module docs are disabled by configuration (enable_module_docs=false)",
  ["module-source-unresolved"] = "Unable to resolve module source URL under cursor",
  ["provider-unresolved"] = "Unable to infer provider from resource/data type under cursor",
  ["url-unresolved"] = "Unable to build Terraform docs URL from current context",
  ["list-context-unresolved"] = "Unable to resolve context for the selected terraform block",
}

-- Reasons for which the resolver still returns a usable (fallback) URL. These
-- are surfaced as info-level notices whenever a docs URL is resolved (open /
-- copy / list), rather than as unresolved errors. The wording is action-neutral
-- because the same resolution backs both open and copy_url.
---@type table<string, string>
local version_fallback_messages = {
  ["lockfile-version-missing"] = "Using fallback version: provider version is missing in .terraform.lock.hcl",
  ["lockfile-version-multiple"] = "Using the first version entry: provider has multiple version entries in .terraform.lock.hcl",
}

---@param trace TfDocsTrace|{ reason?: string, error?: string }|nil
---@return string
local function format_unresolved_message(trace)
  local reason = trace and trace.reason or nil
  if reason == "exception" then
    local detail = trace and trace.error
    if detail and detail ~= "" then
      return string.format("Failed to resolve Terraform docs due to an internal error: %s", detail)
    end
    return "Failed to resolve Terraform docs due to an internal error"
  end

  if reason and unresolved_reason_messages[reason] then
    return unresolved_reason_messages[reason]
  end

  if reason and reason ~= "" then
    return string.format("Failed to resolve Terraform docs (%s)", reason)
  end

  return "Failed to resolve Terraform docs"
end

---Resolve the Terraform docs URL for a buffer without letting the resolver throw.
---@param bufnr number
---@param opts { context?: TfDocsContext, root?: string }|nil
---@return string|nil, TfDocsTrace
local function resolve_safe(bufnr, opts)
  local cfg = config.get()
  local ok, url_or_err, trace = pcall(resolver.resolve, bufnr, opts)
  if not ok then
    log.log(cfg, "error", string.format("tf-docs.nvim: unexpected error: %s", tostring(url_or_err)))
    return nil, { reason = "exception", error = tostring(url_or_err) }
  end
  -- Upgrade to the registry-corrected URL when its slug is already cached, so
  -- the synchronous entry points (resolve/peek/debug) match what open/copy_url
  -- actually open on a warm cache. Cold-cache correction stays async (open/
  -- copy_url/list), since this path must not block.
  if url_or_err and trace then
    local upgraded = registry.resolve_cached_url(trace, url_or_err)
    if upgraded ~= url_or_err then
      url_or_err = upgraded
      trace.url = upgraded
    end
  end
  return url_or_err, trace
end

---@param trace TfDocsTrace|{ reason?: string, error?: string }|nil
local function notify_unresolved(trace)
  local cfg = config.get()
  log.log(cfg, "warn", format_unresolved_message(trace))
end

---Notify (info) when a docs URL was resolved with a version fallback, so the
---user knows the URL may not point at an exact lockfile-pinned version.
---@param trace TfDocsTrace|{ reason?: string }|nil
local function notify_version_fallback(trace)
  local reason = trace and trace.reason or nil
  local msg = reason and version_fallback_messages[reason] or nil
  if msg then
    log.log(config.get(), "info", msg)
  end
end

---Resolve the symbol under the cursor, refine its slug via the Registry (with a
---heuristic fallback on timeout/failure), then hand the final URL to `sink`.
---@param bufnr number|nil
---@param sink fun(url: string)
local function with_resolved_url(bufnr, sink)
  local url, trace = resolve_safe(bufnr or 0)
  if not url then
    notify_unresolved(trace)
    return
  end
  notify_version_fallback(trace)
  registry.resolve_url(trace, url, sink)
end

-- ============================================================================
-- Public API
--
-- These functions are the stable entry points for user keymaps and other
-- plugins. Prefer them over requiring internal modules (tf-docs.resolver,
-- tf-docs.ui, ...), whose layout may change without notice.
-- ============================================================================

---Resolve the symbol under the cursor and open its Terraform Registry docs.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
function M.open(bufnr)
  with_resolved_url(bufnr, function(url)
    ui.open(url)
  end)
end

---Resolve the symbol under the cursor and copy its docs URL to the clipboard.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
function M.copy_url(bufnr)
  with_resolved_url(bufnr, function(url)
    ui.copy(url)
  end)
end

---Show the resolved URL and trace for the symbol under the cursor in a float.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
function M.peek(bufnr)
  local _, trace = resolve_safe(bufnr or 0)
  ui.peek(trace)
end

---List resource/data/module blocks in the buffer and open docs for the choice.
---@param bufnr? number Buffer to list (defaults to the current buffer).
function M.list(bufnr)
  bufnr = bufnr or 0
  local resources = ts.list_resources(bufnr)
  if #resources == 0 then
    log.log(config.get(), "warn", "No terraform resources/data/modules found in current buffer")
    return
  end

  local items = {}
  for _, r in ipairs(resources) do
    local label
    if r.kind == "module" then
      label = string.format("[%s] %s (line %d)", r.kind, r.name, r.line)
    else
      label = string.format("[%s] %s (line %d)", r.kind, r.type, r.line)
    end
    table.insert(items, { label = label, resource = r })
  end

  ui.select(items, {
    prompt = "Select a resource to open docs:",
    format_item = function(item)
      return item.label
    end,
  }, function(selected)
    if not selected then
      return
    end

    local r = selected.resource
    local context = ts.get_context(bufnr, { r.line, 0 })
    if not context then
      notify_unresolved({ reason = "list-context-unresolved" })
      return
    end
    local url, trace = resolve_safe(bufnr, { context = context })

    if not url then
      notify_unresolved(trace)
      return
    end

    notify_version_fallback(trace)
    registry.resolve_url(trace, url, function(final_url)
      ui.open(final_url)
    end)
  end)
end

---Resolve the Terraform docs URL for a buffer.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
---@param opts? { context?: TfDocsContext, root?: string }
---@return string|nil url, TfDocsTrace trace
function M.resolve(bufnr, opts)
  return resolve_safe(bufnr or 0, opts)
end

---Clear tf-docs internal caches (root/provider/lockfile resolution).
function M.clear_cache()
  clear_runtime_cache()
  log.log(config.get(), "info", "tf-docs.nvim cache cleared")
end

local function create_commands()
  if commands_created then
    return
  end

  vim.api.nvim_create_user_command("TfDocOpen", function()
    M.open(0)
  end, {})

  vim.api.nvim_create_user_command("TfDocCopyUrl", function()
    M.copy_url(0)
  end, {})

  vim.api.nvim_create_user_command("TfDocDebug", function()
    local _, trace = resolve_safe(0)
    local info = {
      "tf-docs.nvim trace:",
      string.format("  root: %s", trace.root or "(none)"),
      string.format("  kind: %s", trace.kind or "(none)"),
      string.format("  type: %s", trace.type or "(none)"),
      string.format("  module: %s", trace.module_source or "(none)"),
      string.format("  provider: %s", trace.provider_source or "(none)"),
      string.format("  version: %s", trace.provider_version or "(none)"),
      string.format("  anchor: %s", trace.anchor or "(none)"),
      string.format("  url: %s", trace.url or "(none)"),
      string.format("  reason: %s", trace.reason or "(none)"),
    }
    log.log_force("info", table.concat(info, "\n"))
  end, {})

  vim.api.nvim_create_user_command("TfDocPeek", function()
    M.peek(0)
  end, {})

  vim.api.nvim_create_user_command("TfDocVersion", function()
    local cfg = config.get()
    local root = require("tf-docs.root").get_root(0, cfg)

    if not root then
      log.log(cfg, "warn", "Unable to find Terraform root directory")
      return
    end

    local versions = lockfile.resolve(root)
    local meta = lockfile.get_meta(root)
    local lockfile_path = vim.fs.joinpath(root, ".terraform.lock.hcl")
    local stat = vim.uv.fs_stat(lockfile_path)
    local has_lockfile = stat ~= nil and stat.type == "file"

    ui.show_versions(versions, root, meta, has_lockfile)
  end, {})

  vim.api.nvim_create_user_command("TfDocClearCache", function()
    M.clear_cache()
  end, {})

  vim.api.nvim_create_user_command("TfDocList", function()
    M.list(0)
  end, {})

  commands_created = true
end

local function create_autocmds()
  local cfg = config.get()
  local group = vim.api.nvim_create_augroup(autocmd_group, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufFilePost" }, {
    group = group,
    callback = function(args)
      if args and type(args.buf) == "number" and args.buf > 0 then
        cache.clear_buf(args.buf)
        ts.clear_buf_context(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = clear_runtime_cache,
  })

  local invalidate_patterns = vim.deepcopy(cfg.required_providers_files)
  table.insert(invalidate_patterns, ".terraform.lock.hcl")
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = invalidate_patterns,
    callback = clear_runtime_cache,
  })
end

---@param opts TfDocsOpts|nil
function M.setup(opts)
  config.setup(opts)
  clear_runtime_cache()
  create_commands()
  create_autocmds()
end

return M
