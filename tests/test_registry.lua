local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

local GSA_RESOURCE = "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/resources/service_account"
local GSA_RESOURCE_FIXED =
  "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/resources/google_service_account"

---Stub for registry._http_get_json that dispatches a decoded table by matching
---a literal substring of the requested URL.
---@param responses { match: string, data: table }[]
local function fake_http(responses)
  return function(api, _timeout, cb)
    for _, r in ipairs(responses) do
      if api:find(r.match, 1, true) then
        cb(r.data)
        return
      end
    end
    cb(nil)
  end
end

local function google_responses()
  return {
    {
      match = "/providers/hashicorp/google?",
      data = {
        included = {
          { type = "provider-versions", id = "97186", attributes = { version = "7.33.0" } },
          { type = "provider-versions", id = "98444", attributes = { version = "7.35.0" } },
        },
      },
    },
    {
      match = "filter%5Bslug%5D=google_service_account",
      data = { data = { { attributes = { slug = "google_service_account" } } } },
    },
    -- slug=service_account intentionally has no entry -> falls through to the
    -- next candidate (google_service_account).
  }
end

T["_semver_gt compares numerically and prefers stable releases"] = function()
  local registry = require("tf-docs.registry")
  expect.equality(registry._semver_gt("7.35.0", "7.33.0"), true)
  expect.equality(registry._semver_gt("7.9.0", "7.10.0"), false)
  expect.equality(registry._semver_gt("2.0.0", "2.0.0-rc1"), true)
  expect.equality(registry._semver_gt("1.0.0", "1.0.0"), false)
end

T["_slug_from_url extracts the slug (data-sources hyphen is not a pattern)"] = function()
  local registry = require("tf-docs.registry")
  expect.equality(registry._slug_from_url(GSA_RESOURCE, "resources"), "service_account")
  expect.equality(
    registry._slug_from_url(
      "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/data-sources/service_account",
      "data-sources"
    ),
    "service_account"
  )
  expect.equality(
    registry._slug_from_url(
      "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance#tags-1",
      "resources"
    ),
    "instance"
  )
end

T["_candidates lists heuristic slug then full type, deduplicated"] = function()
  local registry = require("tf-docs.registry")
  expect.equality(
    registry._candidates(GSA_RESOURCE, "resources", "google_service_account"),
    { "service_account", "google_service_account" }
  )
  -- No prefix to strip -> a single candidate.
  expect.equality(
    registry._candidates("https://registry.terraform.io/providers/foo/bar/1.0.0/docs/resources/baz", "resources", "baz"),
    { "baz" }
  )
end

T["_encode_query keeps unreserved chars and percent-encodes the rest"] = function()
  local registry = require("tf-docs.registry")
  expect.equality(registry._encode_query("google_service_account"), "google_service_account")
  expect.equality(registry._encode_query("a-b.c~d_e"), "a-b.c~d_e")
  expect.equality(registry._encode_query("a&b=c d/e"), "a%26b%3Dc%20d%2Fe")
end

T["resolve_cached_url returns corrected URL only when cached and applicable"] = function()
  H.reset_state()
  local registry = require("tf-docs.registry")
  local cache = require("tf-docs.cache")

  local trace = {
    kind = "resource",
    provider_source = "hashicorp/google",
    provider_version = "7.33.0",
    type = "google_service_account",
  }

  -- Not cached -> heuristic fallback unchanged.
  expect.equality(registry.resolve_cached_url(trace, GSA_RESOURCE), GSA_RESOURCE)

  -- Cached -> corrected (anchor preserved).
  cache.set_slug(
    registry._cache_key("hashicorp/google", "7.33.0", "resources", "google_service_account"),
    "google_service_account"
  )
  expect.equality(registry.resolve_cached_url(trace, GSA_RESOURCE), GSA_RESOURCE_FIXED)
  expect.equality(registry.resolve_cached_url(trace, GSA_RESOURCE .. "#email-1"), GSA_RESOURCE_FIXED .. "#email-1")

  -- Not applicable (module / no kind) -> fallback regardless of cache.
  expect.equality(registry.resolve_cached_url({ kind = nil }, "https://example.com/x"), "https://example.com/x")
end

T["resolve_url falls back synchronously when not applicable"] = function()
  H.reset_state()
  local registry = require("tf-docs.registry")

  H.with_patches({
    {
      target = registry,
      key = "_http_get_json",
      value = function()
        error("network must not be touched for non-applicable traces")
      end,
    },
  }, function()
    -- module / unknown kind
    local got
    registry.resolve_url({ kind = nil, url = "https://example.com/x" }, "https://example.com/x", function(u)
      got = u
    end)
    expect.equality(got, "https://example.com/x")

    -- Terraform built-ins use Developer documentation and never query the
    -- provider Registry.
    local builtin_url = "https://developer.hashicorp.com/terraform/language/resources/terraform-data"
    got = nil
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "terraform.io/builtin/terraform",
        type = "terraform_data",
      },
      builtin_url,
      function(u)
        got = u
      end
    )
    expect.equality(got, builtin_url)

    -- custom-host source (not "namespace/name")
    got = nil
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "app.terraform.io/org/google",
        provider_version = "7.33.0",
        type = "google_service_account",
      },
      GSA_RESOURCE,
      function(u)
        got = u
      end
    )
    expect.equality(got, GSA_RESOURCE)

    -- sources with "."/dot-segments are rejected (would otherwise path-normalize)
    for _, bad in ipairs({ "../provider-docs", "a.b/c", "ns/.." }) do
      got = nil
      registry.resolve_url(
        {
          kind = "resource",
          provider_source = bad,
          provider_version = "7.33.0",
          type = "google_service_account",
        },
        GSA_RESOURCE,
        function(u)
          got = u
        end
      )
      expect.equality(got, GSA_RESOURCE)
    end
  end)
end

T["resolve_url falls back when registry lookup is disabled"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ enable_registry_lookup = false })
  local registry = require("tf-docs.registry")

  H.with_patches({
    {
      target = registry,
      key = "_http_get_json",
      value = function()
        error("network must not be touched when disabled")
      end,
    },
  }, function()
    local got
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "hashicorp/google",
        provider_version = "7.33.0",
        type = "google_service_account",
      },
      GSA_RESOURCE,
      function(u)
        got = u
      end
    )
    expect.equality(got, GSA_RESOURCE)
  end)
end

T["resolve_url resolves the real slug via the API and caches it"] = function()
  H.reset_state()
  local registry = require("tf-docs.registry")

  local trace = {
    kind = "resource",
    provider_source = "hashicorp/google",
    provider_version = "7.33.0",
    type = "google_service_account",
  }

  local got
  H.with_patches({
    { target = registry, key = "_http_get_json", value = fake_http(google_responses()) },
  }, function()
    registry.resolve_url(trace, GSA_RESOURCE, function(u)
      got = u
    end)
  end)
  expect.equality(got, GSA_RESOURCE_FIXED)

  -- Slug is cached: a second call must not touch the network.
  local got2
  H.with_patches({
    {
      target = registry,
      key = "_http_get_json",
      value = function()
        error("cache miss: network was touched on a warm cache")
      end,
    },
  }, function()
    registry.resolve_url(trace, GSA_RESOURCE, function(u)
      got2 = u
    end)
  end)
  expect.equality(got2, GSA_RESOURCE_FIXED)
end

T["resolve_url preserves the anchor when rewriting the slug"] = function()
  H.reset_state()
  local registry = require("tf-docs.registry")

  local got
  H.with_patches({
    { target = registry, key = "_http_get_json", value = fake_http(google_responses()) },
  }, function()
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "hashicorp/google",
        provider_version = "7.33.0",
        type = "google_service_account",
      },
      GSA_RESOURCE .. "#email-1",
      function(u)
        got = u
      end
    )
  end)
  expect.equality(got, GSA_RESOURCE_FIXED .. "#email-1")
end

T["resolve_url serves a cached slug without hitting the network"] = function()
  H.reset_state()
  local registry = require("tf-docs.registry")
  local cache = require("tf-docs.cache")

  cache.set_slug(
    registry._cache_key("hashicorp/google", "7.33.0", "resources", "google_service_account"),
    "google_service_account"
  )

  local got
  H.with_patches({
    {
      target = registry,
      key = "_http_get_json",
      value = function()
        error("warm cache must not touch the network")
      end,
    },
  }, function()
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "hashicorp/google",
        provider_version = "7.33.0",
        type = "google_service_account",
      },
      GSA_RESOURCE,
      function(u)
        got = u
      end
    )
  end)
  expect.equality(got, GSA_RESOURCE_FIXED)
end

T["resolve_url falls back to the heuristic URL on timeout"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ registry_timeout_ms = 30 })
  local registry = require("tf-docs.registry")

  local got
  H.with_patches({
    {
      target = registry,
      key = "_http_get_json",
      -- Never invokes the callback: simulates a slow/unresponsive API.
      value = function() end,
    },
  }, function()
    registry.resolve_url(
      {
        kind = "resource",
        provider_source = "hashicorp/google",
        provider_version = "7.33.0",
        type = "google_service_account",
      },
      GSA_RESOURCE,
      function(u)
        got = u
      end
    )
    vim.wait(2000, function()
      return got ~= nil
    end, 10)
  end)
  expect.equality(got, GSA_RESOURCE)
end

return T
