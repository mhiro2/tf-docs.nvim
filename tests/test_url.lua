local MiniTest = require("mini.test")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["resource_url strips the provider prefix (heuristic)"] = function()
  local url = require("tf-docs.url")
  expect.equality(
    url.resource_url("hashicorp/google", "7.33.0", "google_service_account", "google"),
    "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/resources/service_account"
  )
end

T["docs_url builds from an explicit slug without stripping"] = function()
  local url = require("tf-docs.url")
  expect.equality(
    url.docs_url("hashicorp/google", "7.33.0", "resources", "google_service_account"),
    "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/resources/google_service_account"
  )
  expect.equality(
    url.docs_url("hashicorp/google", "7.33.0", "data-sources", "service_account"),
    "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/data-sources/service_account"
  )
end

return T
