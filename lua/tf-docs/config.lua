---@class TfDocsConfig
---@field root_markers string[]
---@field default_namespace string
---@field default_version string
---@field required_providers_files string[]
---@field enable_anchor boolean
---@field anchor_providers_allowlist string[]
---@field provider_overrides table<string, string>
---@field enable_module_docs boolean
---@field log_level string

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
        vim.inspect(cfg.log_level),
        default_config.log_level
      )
    )
    cfg.log_level = default_config.log_level
  end

  cfg.root_markers = sanitize_string_list(cfg.root_markers)
  if #cfg.root_markers == 0 then
    cfg.root_markers = vim.deepcopy(default_config.root_markers)
  end

  cfg.required_providers_files = sanitize_string_list(cfg.required_providers_files)
  if #cfg.required_providers_files == 0 then
    cfg.required_providers_files = vim.deepcopy(default_config.required_providers_files)
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

  return cfg
end

default_config = {
  root_markers = { ".terraform.lock.hcl", "terraform.tf", "main.tf", ".git" },
  default_namespace = "hashicorp",
  default_version = "latest",
  required_providers_files = { "versions.tf", "providers.tf", "main.tf", "terraform.tf" },
  enable_anchor = true,
  anchor_providers_allowlist = { "hashicorp/aws", "hashicorp/google", "hashicorp/azurerm" },
  provider_overrides = {},
  enable_module_docs = true,
  log_level = "warn",
}

---@type TfDocsConfig
local current = vim.deepcopy(default_config)

---@param opts TfDocsConfig|nil
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
