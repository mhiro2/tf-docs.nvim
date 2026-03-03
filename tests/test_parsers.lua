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

T["required_providers ignores braces in strings/comments and merges multiple blocks"] = function()
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

T["module_url cleans VCS subdir and ref"] = function()
  H.reset_state()
  local url = require("tf-docs.url")
  local out = url.module_url("git::https://github.com/org/repo.git//subdir?ref=v1.2.3")
  expect.equality(out, "https://github.com/org/repo.git")
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
