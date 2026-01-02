local M = {}

local function escape_lua_pattern(str)
  return str:gsub("([^%w])", "%%%1")
end

---@param source string
---@param version string
---@return string
function M.provider_base(source, version)
  return string.format("https://registry.terraform.io/providers/%s/%s/docs", source, version)
end

---@param source string
---@param version string
---@param type_name string
---@param type_prefix string
---@return string
function M.resource_url(source, version, type_name, type_prefix)
  local prefix = escape_lua_pattern(type_prefix) .. "_"
  local resource = type_name:gsub("^" .. prefix, "")
  return M.provider_base(source, version) .. "/resources/" .. resource
end

---@param source string
---@param version string
---@param type_name string
---@param type_prefix string
---@return string
function M.data_url(source, version, type_name, type_prefix)
  local prefix = escape_lua_pattern(type_prefix) .. "_"
  local data_name = type_name:gsub("^" .. prefix, "")
  return M.provider_base(source, version) .. "/data-sources/" .. data_name
end

---@param source string
---@return string|nil
function M.module_url(source)
  if not source or source == "" then
    return nil
  end

  local cleaned = source:gsub("^git::", "")

  -- Best-effort cleanup for VCS module sources:
  -- - strip query (e.g. ?ref=...)
  -- - drop Terraform subdir syntax (//subdir)
  cleaned = cleaned:gsub("%?.*$", "")

  -- Common form: https://host/org/repo(.git)//subdir
  cleaned = cleaned:gsub("%.git//.*$", ".git")

  local scheme_start = cleaned:find("://", 1, true)
  if scheme_start then
    local rest = cleaned:sub(scheme_start + 3)
    local idx = rest:find("//", 1, true)
    if idx then
      cleaned = cleaned:sub(1, scheme_start + 2) .. rest:sub(1, idx - 1)
    end
  else
    local idx = cleaned:find("//", 1, true)
    if idx then
      cleaned = cleaned:sub(1, idx - 1)
    end
  end

  if cleaned:match("^https?://") or cleaned:match("^ssh://") or cleaned:match("^git@") then
    return cleaned
  end

  local ns, name, provider = cleaned:match("^([^/]+)/([^/]+)/([^/]+)$")
  if ns and name and provider then
    return string.format("https://registry.terraform.io/modules/%s/%s/%s", ns, name, provider)
  end

  local registry = cleaned:match("^registry%.terraform%.io/(.+)$")
  if registry then
    local ns2, name2, provider2 = registry:match("^([^/]+)/([^/]+)/([^/]+)$")
    if ns2 and name2 and provider2 then
      return string.format("https://registry.terraform.io/modules/%s/%s/%s", ns2, name2, provider2)
    end
  end

  return nil
end

---@param url string
---@param anchor string|nil
---@return string
function M.with_anchor(url, anchor)
  if not anchor or anchor == "" then
    return url
  end
  -- Terraform Registry docs use `#<name>-1` for argument/attribute deep links.
  -- Examples:
  -- - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami#id-1
  -- - https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance#tags-1
  --
  -- If a numeric suffix is already present, don't add another one.
  local normalized = anchor
  if not normalized:match("%-%d+$") then
    normalized = normalized .. "-1"
  end
  return url .. "#" .. normalized
end

return M
