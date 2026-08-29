local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["required_providers parses basic block"] = function()
  H.reset_state()
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

T["required_providers normalizes registry.terraform.io prefix"] = function()
  H.reset_state()
  local parser = require("tf-docs.required_providers")
  local text = [[
terraform {
  required_providers {
    aws = {
      source = "registry.terraform.io/hashicorp/aws"
    }
    google = {
      source = "registry.terraform.io/hashicorp/google"
    }
  }
}
]]
  local result = parser.parse_text(text)
  expect.equality(result.aws, "hashicorp/aws")
  expect.equality(result.google, "hashicorp/google")
end

T["required_providers ignores strings comments and heredocs and merges multiple blocks"] = function()
  H.reset_state()
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
    aws = {
      source = "hashicorp/aws" // inline should override (same value here)
    }
    google = {
      // comment with braces { } should not break
      note = <<-EOT
        source = "example/false"
      }
      EOT
      source = "hashicorp/google"
    }
  }
}
]]
  local result = parser.parse_text(text)
  expect.equality(result.aws, "hashicorp/aws")
  expect.equality(result.google, "hashicorp/google")
end

T["required_providers treats legacy strings and source-less objects as declarations without sources"] = function()
  H.reset_state()
  local parser = require("tf-docs.required_providers")
  local result, declared = parser.parse_text([[
terraform {
  required_providers {
    aws = "~> 5.0"
    google = { version = "~> 6.0" }
  }
}
]])

  expect.equality(next(result), nil)
  expect.equality(declared.aws, true)
  expect.equality(declared.google, true)
end

T["required_providers parses Terraform JSON object and array forms"] = function()
  H.reset_state()
  local parser = require("tf-docs.required_providers")
  local object_result, object_declared = parser.parse_json([[
{
  "terraform": {
    "required_providers": {
      "aws": { "source": "registry.terraform.io/hashicorp/aws" },
      "google": "~> 6.0"
    }
  }
}
]])
  expect.equality(object_result.aws, "hashicorp/aws")
  expect.equality(object_result.google, nil)
  expect.equality(object_declared.google, true)

  local array_result, array_declared = parser.parse_json([[
{
  "terraform": [
    { "required_version": ">= 1.0" },
    { "required_providers": { "azurerm": { "source": "hashicorp/azurerm" } } }
  ]
}
]])
  expect.equality(array_result.azurerm, "hashicorp/azurerm")
  expect.equality(array_declared.azurerm, true)
  local invalid_result = parser.parse_json("{ invalid")
  expect.equality(next(invalid_result), nil)
end

T["lockfile parses versions"] = function()
  H.reset_state()
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
  H.reset_state()
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
  H.reset_state()
  local url = require("tf-docs.url")
  local resource = url.resource_url("hashicorp/aws", "1.2.3", "aws_instance", "aws")
  local data = url.data_url("hashicorp/aws", "1.2.3", "aws_ami", "aws")
  expect.equality(resource, "https://registry.terraform.io/providers/hashicorp/aws/1.2.3/docs/resources/instance")
  expect.equality(data, "https://registry.terraform.io/providers/hashicorp/aws/1.2.3/docs/data-sources/ami")
end

T["module_url cleans VCS subdir, ref, and trailing .git"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  local out = url.module_url("git::https://github.com/org/repo.git//subdir?ref=v1.2.3")
  expect.equality(out, "https://github.com/org/repo")
end

T["module_url normalizes SCP-like git@ sources to https"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(url.module_url("git@github.com:org/repo.git"), "https://github.com/org/repo")
  expect.equality(url.module_url("git::git@github.com:org/repo.git//modules/foo?ref=v1"), "https://github.com/org/repo")
end

T["module_url normalizes ssh git sources to https"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(url.module_url("ssh://git@github.com/org/repo.git"), "https://github.com/org/repo")
  expect.equality(url.module_url("git::ssh://git@gitlab.com/org/repo.git//sub"), "https://gitlab.com/org/repo")
end

T["module_url drops ssh port and userinfo to avoid confusable URLs"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  -- SSH port must not leak into the browsable URL.
  expect.equality(url.module_url("ssh://git@github.com:22/org/repo.git"), "https://github.com/org/repo")
  -- A userinfo that looks like a host must not survive as https://host@other.
  expect.equality(url.module_url("ssh://github.com@evil.example/org/repo.git"), "https://evil.example/org/repo")
  -- Multiple '@' must resolve to the host after the last '@' (no host@other).
  expect.equality(url.module_url("ssh://git@github.com@evil.example/org/repo.git"), "https://evil.example/org/repo")
  expect.equality(url.module_url("git@github.com@evil.example:org/repo.git"), "https://evil.example/org/repo")
  -- A host:port/path registry source without userinfo is not SCP syntax.
  expect.equality(url.module_url("localhost:5000/ns/name/provider"), nil)
end

T["module_url keeps registry shorthand and resolves it"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(
    url.module_url("terraform-aws-modules/vpc/aws"),
    "https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws"
  )
  expect.equality(
    url.module_url("registry.terraform.io/terraform-aws-modules/vpc/aws"),
    "https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws"
  )
end

T["module_url recognizes GitHub and Bitbucket shorthands before Registry modules"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(
    url.module_url("github.com/hashicorp/example//modules/vpc?ref=v1.2.0"),
    "https://github.com/hashicorp/example"
  )
  expect.equality(
    url.module_url("bitbucket.org/hashicorp/example.git?ref=v1.2.0"),
    "https://bitbucket.org/hashicorp/example"
  )
  expect.equality(url.module_url("example.com/hashicorp/example"), nil)
end

T["module_url removes HTTP credentials and query secrets"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  local resolved, safe_source = url.module_url("https://user:secret@example.com/org/repo.git?token=secret")
  expect.equality(resolved, "https://example.com/org/repo")
  expect.equality(safe_source, "https://example.com/org/repo")
  expect.equality(
    url.module_url("http://user@example.com:8080/org/repo.git//modules/vpc?ref=v1"),
    "http://example.com:8080/org/repo"
  )
  expect.equality(url.module_url("https://github.com@evil.example/org/repo.git"), "https://evil.example/org/repo")
end

T["module_url rejects malformed or unsafe authorities"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(url.module_url("https://user@:443/org/repo.git"), nil)
  expect.equality(url.module_url("https://example..com/org/repo.git"), nil)
  expect.equality(url.module_url("https://example.com/org/repo.git\nsecret"), nil)
  expect.equality(url.module_url("https://[2001:db8::1]/org/repo.git"), nil)
  expect.equality(url.module_url("https://[....]/org/repo.git"), nil)
  expect.equality(url.module_url("https://[:::]/org/repo.git"), nil)
end

T["module_url validates HTTP and SSH port boundaries"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  expect.equality(url.module_url("https://example.com:65535/org/repo.git"), "https://example.com:65535/org/repo")
  expect.equality(url.module_url("https://example.com:0/org/repo.git"), nil)
  expect.equality(url.module_url("https://example.com:65536/org/repo.git"), nil)
  expect.equality(url.module_url("ssh://git@example.com:65535/org/repo.git"), "https://example.com/org/repo")
  expect.equality(url.module_url("ssh://git@example.com:0/org/repo.git"), nil)
  expect.equality(url.module_url("ssh://git@example.com:65536/org/repo.git"), nil)
end

T["required_providers.resolve scans arbitrary Terraform files in a module"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local module_dir = vim.fn.tempname()
  vim.fn.mkdir(module_dir, "p")
  vim.fn.writefile({
    'terraform { required_providers { aws = { source = "acme/aws" } } }',
  }, vim.fs.joinpath(module_dir, "network.tf"))
  vim.fn.writefile({
    '{"terraform":{"required_providers":{"google":{"source":"acme/google"}}}}',
  }, vim.fs.joinpath(module_dir, "dependencies.tf.json"))
  vim.fn.writefile({
    'terraform { required_providers { ignored = { source = "acme/ignored" } } }',
  }, vim.fs.joinpath(module_dir, ".generated.tf"))
  vim.fn.writefile({
    '{"terraform":{"required_providers":{"hidden_json":{"source":"acme/hidden"}}}}',
  }, vim.fs.joinpath(module_dir, ".generated.tf.json"))
  vim.fn.writefile({
    'terraform { required_providers { backup = { source = "acme/backup" } } }',
  }, vim.fs.joinpath(module_dir, "network.tf~"))
  vim.fn.writefile({
    'terraform { required_providers { editor_backup = { source = "acme/editor" } } }',
  }, vim.fs.joinpath(module_dir, "#network.tf#"))
  vim.fn.mkdir(vim.fs.joinpath(module_dir, "nested"), "p")
  vim.fn.writefile({
    'terraform { required_providers { nested = { source = "acme/nested" } } }',
  }, vim.fs.joinpath(module_dir, "nested", "main.tf"))

  local got = required_providers.resolve(module_dir)
  expect.equality(got.aws, "acme/aws")
  expect.equality(got.google, "acme/google")
  expect.equality(got.ignored, nil)
  expect.equality(got.hidden_json, nil)
  expect.equality(got.backup, nil)
  expect.equality(got.editor_backup, nil)
  expect.equality(got.nested, nil)

  vim.fn.delete(module_dir, "rf")
end

T["required_providers.resolve applies mixed override files in Terraform order"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local module_dir = vim.fn.tempname()
  vim.fn.mkdir(module_dir, "p")
  vim.fn.writefile({
    "terraform {",
    "  required_providers {",
    '    aws = { source = "base/aws" }',
    '    google = { source = "base/google" }',
    "  }",
    "}",
  }, vim.fs.joinpath(module_dir, "dependencies.tf"))
  vim.fn.writefile({
    '{"terraform":{"required_providers":{"aws":{"source":"json/aws"}}}}',
  }, vim.fs.joinpath(module_dir, "a_override.tf.json"))
  vim.fn.writefile({
    "terraform {",
    "  required_providers {",
    '    aws = { source = "final/aws" }',
    '    google = { version = "~> 6.0" }',
    "  }",
    "}",
  }, vim.fs.joinpath(module_dir, "z_override.tf"))

  local got = required_providers.resolve(module_dir)
  expect.equality(got.aws, "final/aws")
  expect.equality(got.google, "hashicorp/google")

  vim.fn.delete(module_dir, "rf")
end

T["lockfile.resolve normalizes registry.terraform.io/ prefix"] = function()
  H.reset_state()
  local lockfile = require("tf-docs.lockfile")

  local versions = lockfile.resolve(H.fixture_path("integration_project"))
  expect.equality(versions["hashicorp/google-beta"], "4.80.0")
end

T["required_providers cache observes external creation and updates"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local module_dir = vim.fn.tempname()
  vim.fn.mkdir(module_dir, "p")
  local path = vim.fs.joinpath(module_dir, "network.tf")

  expect.equality(next(required_providers.resolve(module_dir)), nil)

  vim.fn.writefile({
    "terraform {",
    "  required_providers {",
    '    aws = { source = "acme/aws" }',
    "  }",
    "}",
  }, path)
  expect.equality(required_providers.resolve(module_dir).aws, "acme/aws")

  vim.fn.writefile({
    "terraform {",
    "  required_providers {",
    '    aws = { source = "examplecorp/aws" }',
    "  }",
    "}",
  }, path)
  expect.equality(required_providers.resolve(module_dir).aws, "examplecorp/aws")

  vim.fn.delete(path)
  expect.equality(next(required_providers.resolve(module_dir)), nil)

  vim.fn.delete(module_dir, "rf")
end

T["lockfile cache observes external creation and updates"] = function()
  H.reset_state()
  local lockfile = require("tf-docs.lockfile")

  local workspace_root = vim.fn.tempname()
  vim.fn.mkdir(workspace_root, "p")
  local path = vim.fs.joinpath(workspace_root, ".terraform.lock.hcl")

  expect.equality(next(lockfile.resolve(workspace_root)), nil)

  vim.fn.writefile({
    'provider "registry.terraform.io/hashicorp/aws" {',
    '  version = "1.0.0"',
    "}",
  }, path)
  expect.equality(lockfile.resolve(workspace_root)["hashicorp/aws"], "1.0.0")

  vim.fn.writefile({
    'provider "registry.terraform.io/hashicorp/aws" {',
    '  version = "12.0.0"',
    "}",
  }, path)
  expect.equality(lockfile.resolve(workspace_root)["hashicorp/aws"], "12.0.0")

  vim.fn.delete(workspace_root, "rf")
end

T["required_providers prefers a modified module buffer over disk"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local module_dir = vim.fn.tempname()
  vim.fn.mkdir(module_dir, "p")
  local path = vim.fs.joinpath(module_dir, "network.tf")
  vim.fn.writefile({
    'terraform { required_providers { aws = { source = "hashicorp/aws" } } }',
  }, path)

  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    { 'terraform { required_providers { aws = { source = "acme/aws" } } }' }
  )
  expect.equality(required_providers.resolve(module_dir).aws, "acme/aws")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  expect.equality(required_providers.resolve(module_dir).aws, "hashicorp/aws")
  vim.fn.delete(module_dir, "rf")
end

T["required_providers cache observes new and edited unsaved module buffers"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local module_dir = vim.fn.tempname()
  vim.fn.mkdir(module_dir, "p")
  local path = vim.fs.joinpath(module_dir, "dependencies.tf")

  expect.equality(next(required_providers.resolve(module_dir)), nil)

  local hidden_bufnr = vim.fn.bufadd(vim.fs.joinpath(module_dir, ".generated.tf"))
  vim.fn.bufload(hidden_bufnr)
  vim.api.nvim_buf_set_lines(
    hidden_bufnr,
    0,
    -1,
    false,
    { 'terraform { required_providers { hidden = { source = "acme/hidden" } } }' }
  )
  expect.equality(next(required_providers.resolve(module_dir)), nil)
  vim.api.nvim_buf_delete(hidden_bufnr, { force = true })

  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    { 'terraform { required_providers { aws = { source = "acme/aws" } } }' }
  )
  expect.equality(vim.uv.fs_stat(path), nil)
  expect.equality(required_providers.resolve(module_dir).aws, "acme/aws")

  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    { 'terraform { required_providers { aws = { source = "examplecorp/aws" } } }' }
  )
  expect.equality(required_providers.resolve(module_dir).aws, "examplecorp/aws")
  vim.api.nvim_buf_delete(bufnr, { force = true })
  expect.equality(next(required_providers.resolve(module_dir)), nil)

  local json_bufnr = vim.fn.bufadd(vim.fs.joinpath(module_dir, "providers.tf.json"))
  vim.fn.bufload(json_bufnr)
  vim.api.nvim_buf_set_lines(
    json_bufnr,
    0,
    -1,
    false,
    { '{"terraform":{"required_providers":{"google":{"source":"acme/google"}}}}' }
  )
  expect.equality(required_providers.resolve(module_dir).google, "acme/google")
  vim.api.nvim_buf_delete(json_bufnr, { force = true })
  expect.equality(next(required_providers.resolve(module_dir)), nil)

  vim.fn.delete(module_dir, "rf")
end

T["required_providers sees a new unsaved buffer through a symlinked module path"] = function()
  H.reset_state()
  local required_providers = require("tf-docs.required_providers")

  local temp_root = vim.fn.tempname()
  local module_dir = vim.fs.joinpath(temp_root, "real-module")
  local linked_dir = vim.fs.joinpath(temp_root, "linked-module")
  vim.fn.mkdir(module_dir, "p")
  local linked, link_error = vim.uv.fs_symlink(module_dir, linked_dir)
  if not linked then
    error(link_error)
  end

  expect.equality(next(required_providers.resolve(linked_dir)), nil)

  local path = vim.fs.joinpath(linked_dir, "network.tf")
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(
    bufnr,
    0,
    -1,
    false,
    { 'terraform { required_providers { aws = { source = "symlink/aws" } } }' }
  )

  expect.equality(required_providers.resolve(linked_dir).aws, "symlink/aws")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(temp_root, "rf")
end

return T
