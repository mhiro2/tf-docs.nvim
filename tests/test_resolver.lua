local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["resolver builds URL with anchor"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    enable_anchor = true,
    anchor_providers_allowlist = { "hashicorp/aws" },
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local resolved_url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "aws_instance",
      anchor_candidate = "tags",
    },
    root = nil,
  })

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance#tags-1"
  )
  expect.equality(trace.provider_source, "hashicorp/aws")
  expect.equality(trace.provider_version, "9.9.9")
end

T["resolver infers provider prefix using first underscore"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local resolved_url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "aws_security_group_rule",
      anchor_candidate = nil,
    },
    root = nil,
  })

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/security_group_rule"
  )
  expect.equality(trace.provider_source, "hashicorp/aws")
end

T["resolver supports provider_overrides without breaking type prefix stripping"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
    provider_overrides = { google = "google-beta" },
  })

  local resolver = require("tf-docs.resolver")
  local resolved_url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "google_compute_instance",
      anchor_candidate = nil,
    },
    root = nil,
  })

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/google-beta/9.9.9/docs/resources/compute_instance"
  )
  expect.equality(trace.provider_source, "hashicorp/google-beta")
end

T["anchor allowlist OFF keeps URL without anchor"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    enable_anchor = true,
    anchor_providers_allowlist = {},
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local resolved_url, _ = resolver.resolve(0, {
    context = { kind = "resource", type = "aws_instance", anchor_candidate = "tags" },
    root = nil,
  })

  expect.equality(resolved_url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance")
end

T["integration: resolver.resolve() works end-to-end with root + ts.get_context"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
    required_providers_files = { "versions.tf" },
    provider_overrides = { google = "google-beta" },
    enable_anchor = true,
    anchor_providers_allowlist = { "hashicorp/google-beta" },
  })

  local resolver = require("tf-docs.resolver")
  local file = H.fixture_path("integration_project", "main.tf")

  local resolved_url, trace = H.with_scratch_buf({
    name = file,
    lines = {
      'resource "google_compute_instance" "x" {',
      "  provider = google.foo",
      "  labels = {",
      '    env = "dev"',
      "  }",
      "}",
    },
    cursor = { 3, 2 },
  }, function(_)
    return resolver.resolve(0)
  end)

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/google-beta/4.80.0/docs/resources/compute_instance#labels-1"
  )
  expect.equality(trace.root, H.fixture_path("integration_project"))
  expect.equality(trace.provider_source, "hashicorp/google-beta")
  expect.equality(trace.provider_version, "4.80.0")
end

return T
