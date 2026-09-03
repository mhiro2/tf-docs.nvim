local config = require("tf-docs.config")
local cache = require("tf-docs.cache")
local lockfile = require("tf-docs.lockfile")
local log = require("tf-docs.log")
local registry = require("tf-docs.registry")
local resolver = require("tf-docs.resolver")
local root = require("tf-docs.root")
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

---@param bufnr number|nil
---@return number
local function normalize_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---@type table<string, string>
local unresolved_reason_messages = {
  ["no-context"] = "No supported Terraform block under cursor",
  ["module-disabled"] = "Module docs are disabled by configuration (enable_module_docs=false)",
  ["module-source-expression"] = "Module source is not a static quoted literal",
  ["module-source-missing"] = "Module block has no source attribute",
  ["module-source-unresolved"] = "Unable to resolve module source URL under cursor",
  ["provider-unresolved"] = "Unable to infer provider from block type under cursor",
  ["url-unresolved"] = "Unable to build Terraform docs URL from current context",
  ["list-context-unresolved"] = "Unable to resolve context for the selected Terraform block",
  ["list-buffer-unavailable"] = "The Terraform buffer was closed while selecting; run :TfDocList again",
  ["list-buffer-changed"] = "The Terraform buffer changed while selecting; run :TfDocList again",
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
---@param bufnr number|nil
---@param opts TfDocsResolveOpts|nil
---@return string|nil, TfDocsTrace
local function resolve_safe(bufnr, opts)
  bufnr = normalize_bufnr(bufnr)
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
---@param opts TfDocsScopeOpts|nil
---@param sink fun(url: string)
local function with_resolved_url(bufnr, opts, sink)
  local url, trace = resolve_safe(bufnr, opts)
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

---Resolve the symbol under the cursor and open its documentation.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
---@param opts? TfDocsScopeOpts Explicit scope overrides.
function M.open(bufnr, opts)
  with_resolved_url(bufnr, opts, function(url)
    ui.open(url)
  end)
end

---Resolve the symbol under the cursor and copy its docs URL to the clipboard.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
---@param opts? TfDocsScopeOpts Explicit scope overrides.
function M.copy_url(bufnr, opts)
  with_resolved_url(bufnr, opts, function(url)
    ui.copy(url)
  end)
end

---Show the resolved URL and trace for the symbol under the cursor in a float.
---@param bufnr? number Buffer to resolve (defaults to the current buffer).
---@param opts? TfDocsScopeOpts Explicit scope overrides.
function M.peek(bufnr, opts)
  local _, trace = resolve_safe(bufnr, opts)
  ui.peek(trace)
end

---Build picker-friendly labels for the blocks returned by `ts.list_blocks`.
---
---Labels use aligned columns so they read well in fuzzy pickers and the
---built-in list alike: `<kind>  <type>.<name>  (line N)`. Modules have no type,
---so their address is just the name.
---@param blocks TfDocsBlock[]
---@return { label: string, block: TfDocsBlock }[]
function M._format_list_items(blocks)
  local addresses = {}
  local kind_width, address_width = 0, 0
  for i, block in ipairs(blocks) do
    local address
    if block.kind == "module" then
      address = block.name
    elseif block.name and block.name ~= "" then
      address = string.format("%s.%s", block.type, block.name)
    else
      address = block.type
    end
    addresses[i] = address
    kind_width = math.max(kind_width, #block.kind)
    address_width = math.max(address_width, #address)
  end

  local items = {}
  for i, block in ipairs(blocks) do
    local label = string.format(
      "%-" .. kind_width .. "s  %-" .. address_width .. "s  (line %d)",
      block.kind,
      addresses[i],
      block.line
    )
    table.insert(items, { label = label, block = block })
  end
  return items
end

---List supported Terraform blocks in the buffer and open docs for the choice.
---@param bufnr? number Buffer to list (defaults to the current buffer).
---@param opts? TfDocsScopeOpts Explicit scope overrides.
function M.list(bufnr, opts)
  bufnr = normalize_bufnr(bufnr)
  local scope_opts = vim.deepcopy(opts or {})
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    notify_unresolved({ reason = "list-buffer-unavailable" })
    return
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local blocks = ts.list_blocks(bufnr)
  if #blocks == 0 then
    log.log(config.get(), "warn", "No supported Terraform blocks found in current buffer")
    return
  end

  local items = M._format_list_items(blocks)

  ui.select(items, {
    prompt = "Select a Terraform block to open docs:",
    kind = ui.SELECT_KIND,
    format_item = function(item)
      return item.label
    end,
  }, function(selected)
    if not selected then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      notify_unresolved({ reason = "list-buffer-unavailable" })
      return
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
      notify_unresolved({ reason = "list-buffer-changed" })
      return
    end

    local block = selected.block
    local context = ts.get_context(bufnr, { block.line, block.col })
    if not context then
      notify_unresolved({ reason = "list-context-unresolved" })
      return
    end
    local resolve_opts = vim.tbl_extend("force", {}, scope_opts, { context = context })
    local url, trace = resolve_safe(bufnr, resolve_opts)

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
---@param opts? TfDocsResolveOpts
---@return string|nil url, TfDocsTrace trace
function M.resolve(bufnr, opts)
  return resolve_safe(bufnr, opts)
end

---Clear tf-docs internal caches.
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
  end, { desc = "tf-docs: open documentation for the symbol under the cursor" })

  vim.api.nvim_create_user_command("TfDocCopyUrl", function()
    M.copy_url(0)
  end, { desc = "tf-docs: copy the docs URL for the symbol under the cursor" })

  vim.api.nvim_create_user_command("TfDocDebug", function()
    local _, trace = resolve_safe(0)
    local info = {
      "tf-docs.nvim trace:",
      string.format("  module directory: %s", trace.module_dir or "(none)"),
      string.format("  workspace root: %s", trace.workspace_root or "(none)"),
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
  end, { desc = "tf-docs: print the resolution trace for the symbol under the cursor" })

  vim.api.nvim_create_user_command("TfDocPeek", function()
    M.peek(0)
  end, { desc = "tf-docs: preview the resolved docs URL and trace in a float" })

  vim.api.nvim_create_user_command("TfDocVersion", function()
    local cfg = config.get()
    local ok, scopes_or_err = pcall(root.resolve_scopes, normalize_bufnr(0), cfg)
    if not ok then
      log.log(cfg, "error", string.format("Unable to resolve Terraform scopes: %s", tostring(scopes_or_err)))
      return
    end
    local workspace_root = scopes_or_err.workspace_root

    if not workspace_root then
      log.log(cfg, "warn", "Unable to find Terraform workspace root")
      return
    end

    local versions = lockfile.resolve(workspace_root)
    local meta = lockfile.get_meta(workspace_root)
    local lockfile_path = vim.fs.joinpath(workspace_root, ".terraform.lock.hcl")
    local stat = vim.uv.fs_stat(lockfile_path)
    local has_lockfile = stat ~= nil and stat.type == "file"

    ui.show_versions(versions, workspace_root, meta, has_lockfile)
  end, { desc = "tf-docs: show provider versions resolved from .terraform.lock.hcl" })

  vim.api.nvim_create_user_command("TfDocClearCache", function()
    M.clear_cache()
  end, { desc = "tf-docs: clear internal resolution caches" })

  vim.api.nvim_create_user_command("TfDocList", function()
    M.list(0)
  end, { desc = "tf-docs: list supported Terraform blocks and open docs for a choice" })

  commands_created = true
end

local function create_autocmds()
  local group = vim.api.nvim_create_augroup(autocmd_group, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufFilePost" }, {
    group = group,
    callback = function(args)
      if args and type(args.buf) == "number" and args.buf > 0 then
        ts.clear_buf_context(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = clear_runtime_cache,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.tf", "*.tf.json", ".terraform.lock.hcl" },
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
