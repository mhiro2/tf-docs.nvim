local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["config validates ui_select_backend with valid values"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({ ui_select_backend = "auto" })
  expect.equality(cfg.ui_select_backend, "auto")

  cfg = config.setup({ ui_select_backend = "builtin" })
  expect.equality(cfg.ui_select_backend, "builtin")

  cfg = config.setup({ ui_select_backend = "vim" })
  expect.equality(cfg.ui_select_backend, "vim")
end

T["config falls back to default for invalid ui_select_backend"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({ ui_select_backend = "invalid" })
  expect.equality(cfg.ui_select_backend, "auto")
end

T["config uses default ui_select_backend when not specified"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({})
  expect.equality(cfg.ui_select_backend, "auto")
end

T["config defaults enable_registry_lookup and registry_timeout_ms"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  local cfg = config.setup({})
  expect.equality(cfg.enable_registry_lookup, true)
  expect.equality(cfg.registry_timeout_ms, 1500)
end

T["config rejects non-finite / sub-1 registry_timeout_ms and floors floats"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  expect.equality(config.setup({ registry_timeout_ms = 0 }).registry_timeout_ms, 1500)
  expect.equality(config.setup({ registry_timeout_ms = 0.5 }).registry_timeout_ms, 1500)
  expect.equality(config.setup({ registry_timeout_ms = -10 }).registry_timeout_ms, 1500)
  expect.equality(config.setup({ registry_timeout_ms = math.huge }).registry_timeout_ms, 1500)
  expect.equality(config.setup({ registry_timeout_ms = 0 / 0 }).registry_timeout_ms, 1500)
  expect.equality(config.setup({ registry_timeout_ms = "x" }).registry_timeout_ms, 1500)
  -- Valid floats are floored to an integer ms for libuv's timer.
  expect.equality(config.setup({ registry_timeout_ms = 1200.9 }).registry_timeout_ms, 1200)
end

T["config falls back for non-boolean enable_registry_lookup"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  expect.equality(config.setup({ enable_registry_lookup = "yes" }).enable_registry_lookup, true)
end

T["config accepts a scope resolver callback"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local callback = function()
    return { module_dir = "/tmp/module" }
  end

  expect.equality(config.setup({ scope_resolver = callback }).scope_resolver, callback)
end

T["config rejects an invalid scope resolver"] = function()
  H.reset_state()
  local config = require("tf-docs.config")

  expect.equality(config.setup({ scope_resolver = "/tmp/module" }).scope_resolver, nil)
end

return T
