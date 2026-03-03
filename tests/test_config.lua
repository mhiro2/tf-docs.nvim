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

return T
