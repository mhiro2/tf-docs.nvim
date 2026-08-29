local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["health.check reports Neovim 0.12+ and optional treesitter parser"] = function()
  H.reset_state()
  local health_module = require("tf-docs.health")

  local calls = {}
  H.with_patches({
    {
      target = vim,
      key = "health",
      value = {
        start = function(name)
          table.insert(calls, { fn = "start", args = { name } })
        end,
        ok = function(msg)
          table.insert(calls, { fn = "ok", args = { msg } })
        end,
        warn = function(msg)
          table.insert(calls, { fn = "warn", args = { msg } })
        end,
        error = function(msg)
          table.insert(calls, { fn = "error", args = { msg } })
        end,
      },
    },
    {
      target = vim,
      key = "version",
      value = setmetatable({
        ge = function()
          return true
        end,
      }, {
        __call = function()
          return { major = 0, minor = 12, patch = 0 }
        end,
      }),
    },
    {
      target = vim,
      key = "treesitter",
      value = {
        language = {
          add = function(lang)
            return lang == "terraform"
          end,
        },
      },
    },
    {
      target = vim,
      key = "ui",
      value = {
        open = function()
          return true
        end,
      },
    },
  }, function()
    health_module.check()
  end)

  expect.equality(calls[1].fn, "start")
  expect.equality(calls[1].args[1], "tf-docs")
  expect.equality(calls[2].args[1], "Neovim 0.12+ detected")
  expect.equality(calls[3].args[1], "vim.ui.open available")
  expect.equality(calls[4].args[1], "treesitter parser available (terraform/hcl, optional)")
end

T["health.check warns when optional treesitter parser is unavailable"] = function()
  H.reset_state()
  local health_module = require("tf-docs.health")

  local calls = {}
  H.with_patches({
    {
      target = vim,
      key = "health",
      value = {
        start = function() end,
        ok = function(msg)
          table.insert(calls, { fn = "ok", msg = msg })
        end,
        warn = function(msg)
          table.insert(calls, { fn = "warn", msg = msg })
        end,
        error = function(msg)
          table.insert(calls, { fn = "error", msg = msg })
        end,
      },
    },
    {
      target = vim,
      key = "version",
      value = setmetatable({
        ge = function()
          return true
        end,
      }, {
        __call = function()
          return { major = 0, minor = 12, patch = 0 }
        end,
      }),
    },
    {
      target = vim,
      key = "treesitter",
      value = {
        language = {
          add = function()
            return false
          end,
        },
      },
    },
    {
      target = vim,
      key = "ui",
      value = {
        open = function()
          return true
        end,
      },
    },
  }, function()
    health_module.check()
  end)

  expect.equality(calls[1].fn, "ok")
  expect.equality(calls[2].fn, "ok")
  expect.equality(calls[3].fn, "warn")
  expect.equality(calls[3].msg, "treesitter parser not detected; tf-docs will use the built-in HCL structure scanner")
end

return T
