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
  })

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/security_group_rule"
  )
  expect.equality(trace.provider_source, "hashicorp/aws")
end

T["resolver supports every provider-backed block kind"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local cases = {
    { kind = "resource", type = "aws_instance", path = "resources/instance" },
    { kind = "data", type = "aws_ami", path = "data-sources/ami" },
    { kind = "ephemeral", type = "aws_ssm_parameter", path = "ephemeral-resources/ssm_parameter" },
    { kind = "action", type = "aws_events_put_events", path = "actions/events_put_events" },
    { kind = "list", type = "aws_vpc", path = "list-resources/vpc" },
  }
  for _, case in ipairs(cases) do
    local resolved_url, trace = resolver.resolve(0, {
      context = {
        kind = case.kind,
        type = case.type,
        anchor_candidate = nil,
      },
    })

    expect.equality(resolved_url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/" .. case.path)
    expect.equality(trace.kind, case.kind)
    expect.equality(trace.provider_source, "hashicorp/aws")
  end
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
  })

  expect.equality(resolved_url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance")
end

T["resolver redacts HTTP, SSH, and SCP credentials from module URL and trace"] = function()
  H.reset_state()
  local resolver = require("tf-docs.resolver")
  local cases = {
    {
      source = "https://user:secret@example.com/org/repo.git?token=secret",
      expected = "https://example.com/org/repo",
    },
    {
      source = "git::ssh://user:secret@example.com:22/org/repo.git//module?token=secret",
      expected = "https://example.com/org/repo",
    },
    {
      source = "secret@example.com:org/repo.git//module?token=secret",
      expected = "https://example.com/org/repo",
    },
  }

  for _, case in ipairs(cases) do
    local resolved_url, trace = resolver.resolve(0, {
      context = {
        kind = "module",
        module_source = case.source,
      },
    })

    expect.equality(resolved_url, case.expected)
    expect.equality(trace.module_source, case.expected)
    expect.equality(trace.url, case.expected)
  end
end

T["integration: resolver.resolve() works end-to-end with workspace discovery + ts.get_context"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
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
  expect.equality(trace.module_dir, H.fixture_path("integration_project"))
  expect.equality(trace.workspace_root, H.fixture_path("integration_project"))
  expect.equality(trace.provider_source, "hashicorp/google-beta")
  expect.equality(trace.provider_version, "4.80.0")
end

T["resolver preserves the explicit reason for a module source expression"] = function()
  H.reset_state()
  local resolver = require("tf-docs.resolver")
  local resolved_url, trace = resolver.resolve(0, {
    context = {
      kind = "module",
      module_source = nil,
      module_source_reason = "module-source-expression",
    },
  })

  expect.equality(resolved_url, nil)
  expect.equality(trace.module_source_reason, "module-source-expression")
  expect.equality(trace.reason, "module-source-expression")
end

T["resolver reads provider source from the module and version from the workspace"] = function()
  H.reset_state()
  local resolver = require("tf-docs.resolver")
  local file = H.fixture_path("workspace_scope", "modules", "network", "resource.tf")

  local resolved_url, trace = H.with_scratch_buf(
    { name = file, lines = { 'resource "aws_instance" "x" {}' } },
    function(bufnr)
      return resolver.resolve(bufnr, {
        context = { kind = "resource", type = "aws_instance" },
      })
    end
  )

  expect.equality(resolved_url, "https://registry.terraform.io/providers/acme/aws/7.8.9/docs/resources/instance")
  expect.equality(trace.module_dir, H.fixture_path("workspace_scope", "modules", "network"))
  expect.equality(trace.workspace_root, H.fixture_path("workspace_scope"))
  expect.equality(trace.provider_source, "acme/aws")
  expect.equality(trace.provider_version, "7.8.9")
end

T["source-less override uses the implied provider instead of a stale lockfile source"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local resolver = require("tf-docs.resolver")
  config.setup({ default_version = "9.9.9" })

  local workspace_root = vim.fn.tempname()
  local module_dir = vim.fs.joinpath(workspace_root, "module")
  vim.fn.mkdir(module_dir, "p")
  vim.fn.writefile({
    'terraform { required_providers { google = { source = "acme/google" } } }',
  }, vim.fs.joinpath(module_dir, "dependencies.tf"))
  vim.fn.writefile({
    'terraform { required_providers { google = { version = "~> 6.0" } } }',
  }, vim.fs.joinpath(module_dir, "override.tf"))
  vim.fn.writefile({
    'provider "registry.terraform.io/acme/google" {',
    '  version = "1.0.0"',
    "}",
  }, vim.fs.joinpath(workspace_root, ".terraform.lock.hcl"))

  local resolved_url, trace = resolver.resolve(0, {
    context = { kind = "resource", type = "google_compute_instance" },
    module_dir = module_dir,
    workspace_root = workspace_root,
  })

  expect.equality(
    resolved_url,
    "https://registry.terraform.io/providers/hashicorp/google/9.9.9/docs/resources/compute_instance"
  )
  expect.equality(trace.provider_source, "hashicorp/google")
  expect.equality(trace.provider_version, "9.9.9")

  vim.fn.delete(workspace_root, "rf")
end

T["resolver sends Terraform built-ins directly to Developer documentation"] = function()
  H.reset_state()
  local lockfile = require("tf-docs.lockfile")
  local required_providers = require("tf-docs.required_providers")
  local resolver = require("tf-docs.resolver")

  local cases = {
    {
      kind = "resource",
      type = "terraform_data",
      url = "https://developer.hashicorp.com/terraform/language/resources/terraform-data",
    },
    {
      kind = "data",
      type = "terraform_remote_state",
      url = "https://developer.hashicorp.com/terraform/language/state/remote-state-data",
    },
  }

  H.with_patches({
    {
      target = required_providers,
      key = "resolve",
      value = function()
        error("built-in resolution must not inspect required_providers")
      end,
    },
    {
      target = lockfile,
      key = "resolve",
      value = function()
        error("built-in resolution must not inspect the dependency lock file")
      end,
    },
  }, function()
    for _, case in ipairs(cases) do
      local resolved_url, trace = resolver.resolve(0, {
        context = { kind = case.kind, type = case.type, anchor_candidate = "id" },
        module_dir = "/tmp/module",
        workspace_root = "/tmp/workspace",
      })
      expect.equality(resolved_url, case.url)
      expect.equality(trace.provider, "terraform")
      expect.equality(trace.provider_source, "terraform.io/builtin/terraform")
      expect.equality(trace.provider_version, nil)
    end
  end)
end

return T
