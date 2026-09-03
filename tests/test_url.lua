local MiniTest = require("mini.test")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["provider_doc_url maps block kinds and strips the provider prefix"] = function()
  local url = require("tf-docs.url")
  local cases = {
    resource = "resources",
    data = "data-sources",
    ephemeral = "ephemeral-resources",
    action = "actions",
    list = "list-resources",
  }
  for kind, category in pairs(cases) do
    expect.equality(
      url.provider_doc_url(kind, "hashicorp/google", "7.33.0", "google_service_account", "google"),
      "https://registry.terraform.io/providers/hashicorp/google/7.33.0/docs/" .. category .. "/service_account"
    )
  end
  expect.equality(url.provider_doc_url("module", "hashicorp/google", "7.33.0", "google_service_account", "google"), nil)
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
