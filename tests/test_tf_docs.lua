local MiniTest = require("mini.test")

local T = MiniTest.new_set()

local expect = MiniTest.expect

local function fixture_path(...)
  return vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", ...)
end

local function with_scratch_buf(opts, fn)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  if opts.name then
    vim.api.nvim_buf_set_name(bufnr, opts.name)
  end
  if opts.lines then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
  end
  if opts.cursor then
    vim.api.nvim_win_set_cursor(0, opts.cursor)
  end

  local ok, a, b, c, d = pcall(fn, bufnr)

  pcall(vim.api.nvim_set_current_buf, prev)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

  if not ok then
    error(a)
  end
  return a, b, c, d
end

local function with_no_treesitter(fn)
  local saved = vim.treesitter
  vim.treesitter = nil
  local ok, a, b, c, d = pcall(fn)
  vim.treesitter = saved
  if not ok then
    error(a)
  end
  return a, b, c, d
end

local function reset_state()
  require("tf-docs.cache").clear()
end

T["required_providers parses basic block"] = function()
  reset_state()
  local parser = require("tf-docs.required_providers")
  local text = [[
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    google = {
      source = "hashicorp/google"
    }
  }
}
]]
  local result = parser.parse_text(text)
  expect.equality(result.aws, "hashicorp/aws")
  expect.equality(result.google, "hashicorp/google")
end

T["required_providers ignores braces in strings/comments and merges multiple blocks"] = function()
  reset_state()
  local parser = require("tf-docs.required_providers")
  local text = [[
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # braces in string should not break: "{ }"
      note = "{ not a block }"
    }
  }
}

terraform {
  required_providers {
    aws = "hashicorp/aws" // inline should override (same value here)
    google = {
      // comment with braces { } should not break
      source = "hashicorp/google"
    }
  }
}
]]
  local result = parser.parse_text(text)
  expect.equality(result.aws, "hashicorp/aws")
  expect.equality(result.google, "hashicorp/google")
end

T["lockfile parses versions"] = function()
  reset_state()
  local parser = require("tf-docs.lockfile")
  local text = [[
provider "registry.terraform.io/hashicorp/aws" {
  version = "5.10.0"
}

provider "registry.terraform.io/hashicorp/google" {
  version = "4.80.0"
}
]]
  local result = parser.parse_text(text)
  expect.equality(result["hashicorp/aws"], "5.10.0")
  expect.equality(result["hashicorp/google"], "4.80.0")
end

T["lockfile ignores provider/version in strings and reports missing/multiple"] = function()
  reset_state()
  local parser = require("tf-docs.lockfile")
  local text = [[
provider "registry.terraform.io/hashicorp/aws" {
  # version is missing here on purpose
  hashes = ["{ not a brace for parsing }", "provider \"x\" { version = \"0\" }"]
}

provider "registry.terraform.io/hashicorp/google" {
  version = "4.80.0"
  version = "4.81.0"
}
]]
  local versions, meta = parser.parse_text(text)
  expect.equality(versions["hashicorp/aws"], nil)
  expect.equality(meta["hashicorp/aws"].version_missing, true)
  expect.equality(versions["hashicorp/google"], "4.80.0")
  expect.equality(meta["hashicorp/google"].version_multiple, true)
end

T["url builder creates resource and data URLs"] = function()
  reset_state()
  local url = require("tf-docs.url")
  local resource = url.resource_url("hashicorp/aws", "1.2.3", "aws_instance", "aws")
  local data = url.data_url("hashicorp/aws", "1.2.3", "aws_ami", "aws")
  expect.equality(resource, "https://registry.terraform.io/providers/hashicorp/aws/1.2.3/docs/resources/instance")
  expect.equality(data, "https://registry.terraform.io/providers/hashicorp/aws/1.2.3/docs/data-sources/ami")
end

T["module_url cleans VCS subdir and ref"] = function()
  reset_state()
  local url = require("tf-docs.url")
  local out = url.module_url("git::https://github.com/org/repo.git//subdir?ref=v1.2.3")
  expect.equality(out, "https://github.com/org/repo.git")
end

T["resolver builds URL with anchor"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({
    enable_anchor = true,
    anchor_providers_allowlist = { "hashicorp/aws" },
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "aws_instance",
      anchor_candidate = "tags",
    },
    root = nil,
  })

  expect.equality(url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance#tags-1")
  expect.equality(trace.provider_source, "hashicorp/aws")
  expect.equality(trace.provider_version, "9.9.9")
end

T["resolver infers provider prefix using first underscore"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "aws_security_group_rule",
      anchor_candidate = nil,
    },
    root = nil,
  })

  expect.equality(url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/security_group_rule")
  expect.equality(trace.provider_source, "hashicorp/aws")
end

T["resolver supports provider_overrides without breaking type prefix stripping"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
    provider_overrides = { google = "google-beta" },
  })

  local resolver = require("tf-docs.resolver")
  local url, trace = resolver.resolve(0, {
    context = {
      kind = "resource",
      type = "google_compute_instance",
      anchor_candidate = nil,
    },
    root = nil,
  })

  expect.equality(
    url,
    "https://registry.terraform.io/providers/hashicorp/google-beta/9.9.9/docs/resources/compute_instance"
  )
  expect.equality(trace.provider_source, "hashicorp/google-beta")
end

T["ts.get_context detects resource and anchor from key ="] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    '  ami = "ami-123"',
    "  tags = {",
    '    Name = "x"',
    "  }",
    "}",
  }
  local ctx = with_scratch_buf({ lines = lines, cursor = { 3, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["ts.get_context detects anchor from block {"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    "  lifecycle {",
    "    create_before_destroy = true",
    "  }",
    "}",
  }
  local ctx = with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "lifecycle")
end

T["ts.get_context extracts provider_hint from provider = google.foo"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "google_compute_instance" "x" {',
    "  provider = google.foo",
    "  labels = {",
    '    env = "dev"',
    "  }",
    "}",
  }
  local ctx = with_scratch_buf({ lines = lines, cursor = { 3, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "google_compute_instance")
  expect.equality(ctx.provider_hint, "google")
end

T["ts.get_context detects module and reads module source"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  source = "registry.terraform.io/terraform-aws-modules/vpc/aws"',
    "}",
  }
  local ctx = with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "registry.terraform.io/terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback ignores braces in strings/comments for module source"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  note = "}"',
    "  # comment with { brace should be ignored",
    '  source = "registry.terraform.io/terraform-aws-modules/vpc/aws"',
    "}",
  }
  local ctx = with_no_treesitter(function()
    return with_scratch_buf({ lines = lines, cursor = { 4, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "registry.terraform.io/terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback works with large files"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {}
  for i = 1, 1200 do
    lines[#lines + 1] = ("# filler %d"):format(i)
  end
  lines[#lines + 1] = 'resource "aws_instance" "x" {'
  lines[#lines + 1] = "  tags = {"
  lines[#lines + 1] = '    Name = "x"'
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"

  local cursor_row = #lines - 3
  local ctx = with_no_treesitter(function()
    return with_scratch_buf({ lines = lines, cursor = { cursor_row, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["root.get_root respects marker priority order"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { "terraform.tf", ".terraform.lock.hcl" } })
  local root = require("tf-docs.root")

  local file = fixture_path("root_priority", "subdir", "main.tf")
  local got = with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.get_root(bufnr, config.get())
  end)

  expect.equality(got, fixture_path("root_priority", "subdir"))
end

T["root.get_root falls back to markers when no lockfile"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { "terraform.tf" } })
  local root = require("tf-docs.root")

  local file = fixture_path("root_marker", "subdir", "foo.tf")
  local got = with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.get_root(bufnr, config.get())
  end)

  expect.equality(got, fixture_path("root_marker"))
end

T["required_providers.resolve merges multiple files (later overrides earlier)"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({ required_providers_files = { "versions.tf", "main.tf" } })
  local rp = require("tf-docs.required_providers")

  local got = rp.resolve(fixture_path("required_merge"), config.get())
  expect.equality(got.aws, "mycorp/aws")
end

T["lockfile.resolve normalizes registry.terraform.io/ prefix"] = function()
  reset_state()
  local lockfile = require("tf-docs.lockfile")

  local versions = lockfile.resolve(fixture_path("integration_project"))
  expect.equality(versions["hashicorp/google-beta"], "4.80.0")
end

T["anchor allowlist OFF keeps URL without anchor"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({
    enable_anchor = true,
    anchor_providers_allowlist = {},
    default_version = "9.9.9",
  })

  local resolver = require("tf-docs.resolver")
  local url, _ = resolver.resolve(0, {
    context = { kind = "resource", type = "aws_instance", anchor_candidate = "tags" },
    root = nil,
  })

  expect.equality(url, "https://registry.terraform.io/providers/hashicorp/aws/9.9.9/docs/resources/instance")
end

T["ts.list_resources returns all resources and data sources"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "web" {',
    '  ami = "ami-123"',
    "}",
    "",
    'data "aws_ami" "ubuntu" {',
    "  most_recent = true",
    "}",
    "",
    'module "vpc" {',
    '  source = "terraform-aws-modules/vpc/aws"',
    "}",
  }
  local resources = with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 3)
  expect.equality(resources[1].kind, "resource")
  expect.equality(resources[1].type, "aws_instance")
  expect.equality(resources[1].name, "web")
  expect.equality(resources[1].line, 1)
  expect.equality(resources[2].kind, "data")
  expect.equality(resources[2].type, "aws_ami")
  expect.equality(resources[2].name, "ubuntu")
  expect.equality(resources[2].line, 5)
  expect.equality(resources[3].kind, "module")
  expect.equality(resources[3].name, "vpc")
  expect.equality(resources[3].line, 9)
end

T["ts.list_resources returns empty table when no resources found"] = function()
  reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    "# Just a comment",
    'variable "foo" {}',
  }
  local resources = with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 0)
end

T["integration: resolver.resolve() works end-to-end with root + ts.get_context"] = function()
  reset_state()
  local config = require("tf-docs.config")
  config.setup({
    default_version = "9.9.9",
    required_providers_files = { "versions.tf" },
    provider_overrides = { google = "google-beta" },
    enable_anchor = true,
    anchor_providers_allowlist = { "hashicorp/google-beta" },
  })

  local resolver = require("tf-docs.resolver")
  local file = fixture_path("integration_project", "main.tf")

  local url, trace = with_scratch_buf({
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
    url,
    "https://registry.terraform.io/providers/hashicorp/google-beta/4.80.0/docs/resources/compute_instance#labels-1"
  )
  expect.equality(trace.root, fixture_path("integration_project"))
  expect.equality(trace.provider_source, "hashicorp/google-beta")
  expect.equality(trace.provider_version, "4.80.0")
end

T["config validates ui_select_backend with valid values"] = function()
  reset_state()
  local config = require("tf-docs.config")

  -- Test auto
  local cfg = config.setup({ ui_select_backend = "auto" })
  expect.equality(cfg.ui_select_backend, "auto")

  -- Test builtin
  cfg = config.setup({ ui_select_backend = "builtin" })
  expect.equality(cfg.ui_select_backend, "builtin")
end

T["config falls back to default for invalid ui_select_backend"] = function()
  reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({ ui_select_backend = "invalid" })
  expect.equality(cfg.ui_select_backend, "auto")
end

T["config uses default ui_select_backend when not specified"] = function()
  reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({})
  expect.equality(cfg.ui_select_backend, "auto")
end

return T
