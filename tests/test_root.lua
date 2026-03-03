local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["root.get_root respects marker priority order"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { "terraform.tf", ".terraform.lock.hcl" } })
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_priority", "subdir", "main.tf")
  local got = H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.get_root(bufnr, config.get())
  end)

  expect.equality(got, H.fixture_path("root_priority", "subdir"))
end

T["root.get_root falls back to markers when no lockfile"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { "terraform.tf" } })
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_marker", "subdir", "foo.tf")
  local got = H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.get_root(bufnr, config.get())
  end)

  expect.equality(got, H.fixture_path("root_marker"))
end

T["setup clears cached root values when root markers change"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_marker", "subdir", "foo.tf")
  H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    plugin.setup({ root_markers = { "terraform.tf" } })
    local first = root.get_root(bufnr, config.get())
    expect.equality(first, H.fixture_path("root_marker"))

    plugin.setup({ root_markers = { ".terraform.lock.hcl" } })
    local second = root.get_root(bufnr, config.get())
    expect.equality(second, nil)
  end)
end

T["BufFilePost invalidates cached root for renamed buffers"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local cache = require("tf-docs.cache")
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  plugin.setup({ root_markers = { "terraform.tf" } })

  local file_a = H.fixture_path("root_marker", "subdir", "foo.tf")
  local file_b = H.fixture_path("root_priority", "subdir", "main.tf")
  H.with_scratch_buf({ name = file_a, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    local first = root.get_root(bufnr, config.get())
    expect.equality(first, H.fixture_path("root_marker"))

    vim.api.nvim_buf_set_name(bufnr, file_b)
    expect.equality(cache.get_root(bufnr), nil)

    local refreshed = root.get_root(bufnr, config.get())
    expect.equality(refreshed, H.fixture_path("root_priority", "subdir"))
  end)
end

return T
