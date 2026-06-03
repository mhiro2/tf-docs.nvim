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

---@param source string
---@return string|nil
function M.module_url(source)
  if not source or source == "" then
    return nil
  end

  -- Best-effort cleanup for VCS module sources:
  -- - strip the git:: forced-protocol prefix and any query (e.g. ?ref=...)
  local cleaned = source:gsub("^git::", "")
  cleaned = cleaned:gsub("%?.*$", "")

  -- Drop the userinfo and port from a "[user@]host[:port]" authority, leaving
  -- just the host. Userinfo is stripped up to the LAST '@' (matching how
  -- browsers resolve "a@b@host"), so a crafted source cannot leave a
  -- confusable "host@other" in the generated https URL.
  local function host_only(authority)
    return (authority:gsub("^.*@", ""):gsub(":%d+$", ""))
  end

  -- Normalize non-browsable VCS schemes to https so vim.ui.open can open them.
  -- ssh://[user@]host[:port]/path -> https://host/path
  local ssh_rest = cleaned:match("^ssh://(.+)$")
  if ssh_rest then
    local authority, path = ssh_rest:match("^([^/]*)(/.*)$")
    if not authority then
      authority, path = ssh_rest, ""
    end
    cleaned = "https://" .. host_only(authority) .. path
  end

  -- SCP-like syntax: user@host:org/repo -> https://host/org/repo. Require an
  -- explicit userinfo '@' so we don't mistake a "host:port/path" registry
  -- source for SCP syntax.
  if not cleaned:find("://", 1, true) and cleaned:find("@", 1, true) then
    local authority, path = cleaned:match("^([^/]+):(.+)$")
    if authority then
      cleaned = "https://" .. host_only(authority) .. "/" .. path
    end
  end

  -- Drop Terraform subdir syntax (//subdir), preserving the scheme's "://".
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

  -- Strip a trailing .git so the URL points at the browsable repo page.
  cleaned = cleaned:gsub("%.git$", "")

  if cleaned:match("^https?://") then
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
