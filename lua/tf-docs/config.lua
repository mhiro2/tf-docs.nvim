---@class TfDocsScopeOpts
---@field module_dir? string
---@field workspace_root? string

---@alias TfDocsScopeResolver fun(bufnr: number): TfDocsScopeOpts|nil

---@class TfDocsConfig
---@field root_markers string[]
---@field scope_resolver TfDocsScopeResolver|nil
---@field default_namespace string
---@field default_version string
---@field enable_anchor boolean
---@field anchor_providers_allowlist string[]
---@field provider_overrides table<string, string>
---@field enable_module_docs boolean
---@field enable_registry_lookup boolean
---@field registry_timeout_ms number
---@field log_level string
---@field ui_select_backend "auto"|"builtin"

--- Partial configuration accepted by setup(). Every field is optional; omitted
--- fields fall back to the defaults, so passing e.g. { default_version = "x" }
--- does not trigger LuaLS "missing fields" warnings.
---@class TfDocsOpts
---@field root_markers? string[]
---@field scope_resolver? TfDocsScopeResolver
---@field default_namespace? string
---@field default_version? string
---@field enable_anchor? boolean
---@field anchor_providers_allowlist? string[]
---@field provider_overrides? table<string, string>
---@field enable_module_docs? boolean
---@field enable_registry_lookup? boolean
---@field registry_timeout_ms? number
---@field log_level? "debug"|"info"|"warn"|"error"
---@field ui_select_backend? "auto"|"builtin"

local M = {}

---@type TfDocsConfig
local default_config

local valid_log_levels = {
  debug = true,
  info = true,
  warn = true,
  error = true,
}

local function warn(msg)
  if vim and vim.notify then
    vim.notify(msg, vim.log.levels.WARN, { title = "tf-docs.nvim" })
  else
    print(msg)
  end
end

---@param value any
---@return string[]
local function sanitize_string_list(value)
  if type(value) ~= "table" then
    return {}
  end
  local out = {}
  for _, v in ipairs(value) do
    if type(v) == "string" and v ~= "" then
      table.insert(out, v)
    end
  end
  return out
end

---@param value any
---@return table<string, string>
local function sanitize_string_map(value)
  if type(value) ~= "table" then
    return {}
  end
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" and k ~= "" and type(v) == "string" and v ~= "" then
      out[k] = v
    end
  end
  return out
end

---@param cfg TfDocsConfig
---@return TfDocsConfig
local function validate(cfg)
  if not valid_log_levels[cfg.log_level] then
    warn(
      string.format(
        "tf-docs.nvim: invalid log_level=%s (fallback to %s)",
        tostring(cfg.log_level),
        default_config.log_level
      )
    )
    cfg.log_level = default_config.log_level
  end

  cfg.root_markers = sanitize_string_list(cfg.root_markers)
  if #cfg.root_markers == 0 then
    cfg.root_markers = vim.deepcopy(default_config.root_markers)
  end

  if cfg.scope_resolver ~= nil and type(cfg.scope_resolver) ~= "function" then
    warn("tf-docs.nvim: scope_resolver must be a function or nil (fallback to automatic scope discovery)")
    cfg.scope_resolver = nil
  end

  cfg.anchor_providers_allowlist = sanitize_string_list(cfg.anchor_providers_allowlist)
  cfg.provider_overrides = sanitize_string_map(cfg.provider_overrides)

  if type(cfg.default_namespace) ~= "string" or cfg.default_namespace == "" then
    warn("tf-docs.nvim: default_namespace must be a non-empty string (fallback to default)")
    cfg.default_namespace = default_config.default_namespace
  end

  if type(cfg.default_version) ~= "string" or cfg.default_version == "" then
    warn("tf-docs.nvim: default_version must be a non-empty string (fallback to default)")
    cfg.default_version = default_config.default_version
  end

  if type(cfg.enable_anchor) ~= "boolean" then
    warn("tf-docs.nvim: enable_anchor must be boolean (fallback to default)")
    cfg.enable_anchor = default_config.enable_anchor
  end

  if type(cfg.enable_module_docs) ~= "boolean" then
    warn("tf-docs.nvim: enable_module_docs must be boolean (fallback to default)")
    cfg.enable_module_docs = default_config.enable_module_docs
  end

  if type(cfg.enable_registry_lookup) ~= "boolean" then
    warn("tf-docs.nvim: enable_registry_lookup must be boolean (fallback to default)")
    cfg.enable_registry_lookup = default_config.enable_registry_lookup
  end

  -- Must be a finite, >= 1 ms value; it is handed to libuv's timer:start(),
  -- which expects a non-negative integer. NaN (t ~= t) and +inf are rejected.
  local timeout = cfg.registry_timeout_ms
  if type(timeout) ~= "number" or timeout ~= timeout or timeout == math.huge or timeout < 1 then
    warn("tf-docs.nvim: registry_timeout_ms must be a finite number of milliseconds >= 1 (fallback to default)")
    cfg.registry_timeout_ms = default_config.registry_timeout_ms
  else
    cfg.registry_timeout_ms = math.floor(timeout)
  end

  local valid_backends = { auto = true, builtin = true }
  if not valid_backends[cfg.ui_select_backend] then
    warn(
      string.format(
        "tf-docs.nvim: invalid ui_select_backend=%s (fallback to %s)",
        tostring(cfg.ui_select_backend),
        default_config.ui_select_backend
      )
    )
    cfg.ui_select_backend = default_config.ui_select_backend
  end

  return cfg
end

default_config = {
  root_markers = { ".terraform.lock.hcl", "terraform.tf", "main.tf", ".git" },
  scope_resolver = nil,
  default_namespace = "hashicorp",
  default_version = "latest",
  enable_anchor = true,
  anchor_providers_allowlist = { "hashicorp/aws", "hashicorp/google", "hashicorp/azurerm" },
  provider_overrides = {},
  enable_module_docs = true,
  enable_registry_lookup = true,
  registry_timeout_ms = 1500,
  log_level = "warn",
  ui_select_backend = "auto",
}

---@type TfDocsConfig
local current = vim.deepcopy(default_config)

---@param opts TfDocsOpts|nil
---@return TfDocsConfig
function M.setup(opts)
  if opts == nil then
    current = vim.deepcopy(default_config)
    return current
  end
  if type(opts) ~= "table" then
    warn("tf-docs.nvim: setup(opts) expects a table; ignoring invalid opts")
    current = vim.deepcopy(default_config)
    return current
  end
  current = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts)
  current = validate(current)
  return current
end

---@return TfDocsConfig
function M.get()
  return current
end

return M
