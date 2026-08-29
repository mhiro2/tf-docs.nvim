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

---Build a docs URL from an explicit, already-resolved slug. Unlike
---resource_url/data_url, this does NOT strip the provider prefix, so it can
---express slugs that keep it (e.g. hashicorp/google's `google_service_account`).
---@param source string
---@param version string
---@param category string "resources" | "data-sources"
---@param slug string
---@return string
function M.docs_url(source, version, category, slug)
  return M.provider_base(source, version) .. "/" .. category .. "/" .. slug
end

local function strip_module_suffixes(source)
  local cleaned = source:match("^[^?#]*") or source
  local scheme_start = cleaned:find("://", 1, true)
  local search_start = scheme_start and scheme_start + 3 or 1
  local subdir_start = cleaned:find("//", search_start, true)
  if subdir_start then
    cleaned = cleaned:sub(1, subdir_start - 1)
  end
  return cleaned:gsub("%.git$", "")
end

---@param authority string
---@param drop_port boolean
---@return string|nil
local function sanitize_authority(authority, drop_port)
  local userinfo_end = authority:match("^.*()@")
  if userinfo_end then
    authority = authority:sub(userinfo_end + 1)
  end
  if authority == "" then
    return nil
  end

  -- IP literals need a real IPv6 parser to validate safely. Hostname sources
  -- cover the supported browsing workflow, so fail closed for bracketed hosts.
  if authority:sub(1, 1) == "[" then
    return nil
  end

  local port_digits = authority:match(":(%d+)$")
  local port = ""
  if port_digits then
    local port_number = tonumber(port_digits)
    if not port_number or port_number < 1 or port_number > 65535 then
      return nil
    end
    port = ":" .. port_digits
  end
  local host = port == "" and authority or authority:sub(1, #authority - #port)
  if
    host == ""
    or host:sub(1, 1) == "."
    or host:sub(-1) == "."
    or host:find("..", 1, true)
    or not host:match("^[%w.-]+$")
  then
    return nil
  end
  return host .. (drop_port and "" or port)
end

---@param value string
---@return boolean
local function is_registry_segment(value)
  return value ~= "" and value:match("^[%w-]+$") ~= nil
end

---@param value string
---@return boolean
local function is_vcs_path_segment(value)
  return value ~= "" and value ~= "." and value ~= ".." and value:match("^[%w._-]+$") ~= nil
end

---@param source string
---@return string|nil url
---@return string|nil safe_source
function M.module_url(source)
  if type(source) ~= "string" or source == "" or source:find("[%z\1-\31\127%s]") then
    return nil, nil
  end

  local cleaned = source:gsub("^git::", "", 1)
  cleaned = cleaned:match("^[^?#]*") or cleaned

  local scheme, http_rest = cleaned:match("^(https?)://(.+)$")
  if scheme then
    local authority, path = http_rest:match("^([^/]*)(/.*)$")
    if not authority then
      authority, path = http_rest, ""
    end
    authority = sanitize_authority(authority, false)
    if not authority then
      return nil, nil
    end
    cleaned = strip_module_suffixes(scheme .. "://" .. authority .. path)
    return cleaned, cleaned
  end

  local ssh_rest = cleaned:match("^ssh://(.+)$")
  if ssh_rest then
    local authority, path = ssh_rest:match("^([^/]*)(/.*)$")
    if not authority then
      authority, path = ssh_rest, ""
    end
    authority = sanitize_authority(authority, true)
    if not authority then
      return nil, nil
    end
    cleaned = strip_module_suffixes("https://" .. authority .. path)
    return cleaned, cleaned
  end

  -- SCP-like syntax: user@host:org/repo -> https://host/org/repo. Requiring
  -- userinfo keeps host:port/path registry-like sources out of this branch.
  if not cleaned:find("://", 1, true) and cleaned:find("@", 1, true) then
    local authority, path = cleaned:match("^([^/]+):(.+)$")
    if not authority then
      return nil, nil
    end
    authority = sanitize_authority(authority, true)
    if not authority then
      return nil, nil
    end
    cleaned = strip_module_suffixes("https://" .. authority .. "/" .. path)
    return cleaned, cleaned
  end

  cleaned = strip_module_suffixes(cleaned)

  -- Terraform recognizes these host shorthands as VCS sources. They must be
  -- classified before the three-part public Registry shorthand.
  local vcs_host, organization, repository = cleaned:match("^([^/]+)/([^/]+)/([^/]+)$")
  if
    (vcs_host == "github.com" or vcs_host == "bitbucket.org")
    and is_vcs_path_segment(organization)
    and is_vcs_path_segment(repository)
  then
    local browse_url = string.format("https://%s/%s/%s", vcs_host, organization, repository)
    return browse_url, cleaned
  end

  local registry = cleaned:match("^registry%.terraform%.io/(.+)$")
  if registry then
    local namespace, name, provider = registry:match("^([^/]+)/([^/]+)/([^/]+)$")
    if
      is_registry_segment(namespace or "")
      and is_registry_segment(name or "")
      and is_registry_segment(provider or "")
    then
      return string.format("https://registry.terraform.io/modules/%s/%s/%s", namespace, name, provider), cleaned
    end
    return nil, nil
  end

  local namespace, name, provider = cleaned:match("^([^/]+)/([^/]+)/([^/]+)$")
  if
    is_registry_segment(namespace or "")
    and is_registry_segment(name or "")
    and is_registry_segment(provider or "")
  then
    return string.format("https://registry.terraform.io/modules/%s/%s/%s", namespace, name, provider), cleaned
  end

  return nil, nil
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
