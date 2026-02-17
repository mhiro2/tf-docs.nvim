local config = require("tf-docs.config")
local cache = require("tf-docs.cache")
local lockfile = require("tf-docs.lockfile")
local log = require("tf-docs.log")
local resolver = require("tf-docs.resolver")
local ui = require("tf-docs.ui")
local ts = require("tf-docs.ts")

local M = {}

local commands_created = false
local autocmd_group = "tf-docs.nvim"

local function clear_runtime_cache()
  cache.clear()
  lockfile.clear_meta()
end

local function create_commands()
  if commands_created then
    return
  end

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
    return url_or_err, trace
  end

  local function notify_unresolved(trace)
    local cfg = config.get()
    local reason = trace and trace.reason
    if reason and reason ~= "" then
      log.log(cfg, "warn", string.format("No terraform resource/data/module under cursor (%s)", reason))
    else
      log.log(cfg, "warn", "No terraform resource/data/module under cursor")
    end
  end

  vim.api.nvim_create_user_command("TfDocOpen", function()
    local url, trace = resolve_safe(0)
    if not url then
      notify_unresolved(trace)
      return
    end
    ui.open(url)
  end, {})

  vim.api.nvim_create_user_command("TfDocCopyUrl", function()
    local url, trace = resolve_safe(0)
    if not url then
      notify_unresolved(trace)
      return
    end
    ui.copy(url)
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
    local _, trace = resolve_safe(0)
    ui.peek(trace)
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
    cache.clear()
    lockfile.clear_meta()
    log.log(config.get(), "info", "tf-docs.nvim cache cleared")
  end, {})

  vim.api.nvim_create_user_command("TfDocList", function()
    local resources = ts.list_resources(0)
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
      local context = ts.get_context(0, { r.line, 0 })
      if not context then
        notify_unresolved({ reason = "list-context-unresolved" })
        return
      end
      local url, trace = resolve_safe(0, { context = context })

      if not url then
        notify_unresolved(trace)
        return
      end

      ui.open(url)
    end)
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

---@param opts TfDocsConfig|nil
function M.setup(opts)
  config.setup(opts)
  clear_runtime_cache()
  create_commands()
  create_autocmds()
end

return M
