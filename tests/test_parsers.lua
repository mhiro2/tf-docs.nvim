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
    aws = "registry.terraform.io/hashicorp/aws"
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
    aws = "hashicorp/aws" // inline should override (same value here)
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

T["required_providers.resolve merges multiple files (later overrides earlier)"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ required_providers_files = { "versions.tf", "main.tf" } })
  local rp = require("tf-docs.required_providers")

  local got = rp.resolve(H.fixture_path("required_merge"), config.get())
  expect.equality(got.aws, "mycorp/aws")
end

T["lockfile.resolve normalizes registry.terraform.io/ prefix"] = function()
  H.reset_state()
  local lockfile = require("tf-docs.lockfile")

  local versions = lockfile.resolve(H.fixture_path("integration_project"))
  expect.equality(versions["hashicorp/google-beta"], "4.80.0")
end

return T
