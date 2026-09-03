local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["ui.open treats nil return from vim.ui.open as failure"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")
  local log = require("tf-docs.log")

  local logs = {}
  local ok = H.with_patches({
    {
      target = vim,
      key = "ui",
      value = {
        open = function(url)
          expect.equality(url, "https://example.com")
          return nil, "browser unavailable"
        end,
      },
    },
    {
      target = log,
      key = "log",
      value = function(_, level, msg)
        table.insert(logs, { level = level, msg = msg })
      end,
    },
  }, function()
    return ui.open("https://example.com")
  end)

  expect.equality(ok, false)
  expect.equality(#logs, 1)
  expect.equality(logs[1].level, "error")
  expect.equality(logs[1].msg, "vim.ui.open failed: browser unavailable")
end

T["ui.open refuses non-http(s) URLs without calling vim.ui.open"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")
  local log = require("tf-docs.log")

  local logs = {}
  local open_calls = 0
  local ok = H.with_patches({
    {
      target = vim,
      key = "ui",
      value = {
        open = function()
          open_calls = open_calls + 1
          return true
        end,
      },
    },
    {
      target = log,
      key = "log",
      value = function(_, level, msg)
        table.insert(logs, { level = level, msg = msg })
      end,
    },
  }, function()
    return ui.open("ssh://git@github.com/org/repo")
  end)

  expect.equality(ok, false)
  expect.equality(open_calls, 0)
  expect.equality(#logs, 1)
  expect.equality(logs[1].level, "warn")
  expect.equality(logs[1].msg, "Refusing to open non-http(s) URL: ssh://git@github.com/org/repo")
end

T["ui.open allows http(s) URLs"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")

  local opened
  local ok = H.with_patches({
    {
      target = vim,
      key = "ui",
      value = {
        open = function(url)
          opened = url
          return true
        end,
      },
    },
  }, function()
    return ui.open("http://registry.terraform.io/x")
  end)

  expect.equality(ok, true)
  expect.equality(opened, "http://registry.terraform.io/x")
end

T["ui.open accepts uppercase http(s) scheme and preserves the original URL"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")

  local opened
  local ok = H.with_patches({
    {
      target = vim,
      key = "ui",
      value = {
        open = function(url)
          opened = url
          return true
        end,
      },
    },
  }, function()
    return ui.open("HTTPS://registry.terraform.io/Path")
  end)

  expect.equality(ok, true)
  -- The scheme check is case-insensitive, but the original URL is opened as-is.
  expect.equality(opened, "HTTPS://registry.terraform.io/Path")
end

T["ui versions view shows missing lockfile and empty providers"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")

  local lines = ui._build_versions_lines({}, "/root", {}, false)
  expect.equality(lines[1], "tf-docs.nvim - Provider Versions")
  expect.equality(lines[3], "Workspace root: /root")
  expect.equality(lines[4], "Lockfile: .terraform.lock.hcl (missing)")
  expect.equality(lines[6], "(no providers found)")
end

T["ui versions view sorts, aligns, and annotates providers"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")

  local versions = {
    ["hashicorp/zb\tfoo"] = "1.2.3",
    ["hashicorp/aws"] = "5.0.0",
  }
  local meta = {
    ["hashicorp/aws"] = { version_multiple = true },
    ["hashicorp/google"] = { version_missing = true },
  }

  local lines = ui._build_versions_lines(versions, "/root", meta, true)
  local provider_lines = {}
  for _, line in ipairs(lines) do
    if line:match("^hashicorp/") then
      table.insert(provider_lines, line)
    end
  end

  expect.equality(#provider_lines, 3)

  local expected_sources = { "hashicorp/aws", "hashicorp/google", "hashicorp/zb\tfoo" }
  for i, line in ipairs(provider_lines) do
    local source_part = line:match("^(.*)  [^ ].*$")
    expect.equality(vim.trim(source_part), expected_sources[i])
  end

  local max_width = 0
  for _, source in ipairs(expected_sources) do
    max_width = math.max(max_width, vim.api.nvim_strwidth(source))
  end
  for _, line in ipairs(provider_lines) do
    local source_part = line:match("^(.*)  [^ ].*$")
    expect.equality(vim.api.nvim_strwidth(source_part), max_width)
  end

  expect.equality(provider_lines[1]:match("^.*  ([^ ].+)$"), "5.0.0 (multiple)")
  expect.equality(provider_lines[2]:match("^.*  ([^ ].+)$"), "(missing)")
  expect.equality(provider_lines[3]:match("^.*  ([^ ].+)$"), "1.2.3")
end

T["ui window size clamp enforces safe lower/upper bounds"] = function()
  H.reset_state()
  local ui = require("tf-docs.ui")

  expect.equality(ui._clamp_window_size(5, 20, 100), 20)
  expect.equality(ui._clamp_window_size(50, 20, 100), 50)
  expect.equality(ui._clamp_window_size(500, 20, 100), 100)
  expect.equality(ui._clamp_window_size(1, 20, 10), 10)
  expect.equality(ui._clamp_window_size(1, 20, -1), 1)
end

T["ui backend detection is cached after first auto-detect"] = function()
  H.reset_state()
  local backend = require("tf-docs.ui_backend")

  local saved_telescope = package.loaded["telescope"]
  local saved_telescope_ext = package.loaded["telescope._extensions.ui-select"]
  local saved_fzf = package.loaded["fzf-lua"]
  local saved_snacks = package.loaded["snacks.picker"]

  package.loaded["telescope"] = {}
  package.loaded["telescope._extensions.ui-select"] = {}
  package.loaded["fzf-lua"] = nil
  package.loaded["snacks.picker"] = nil

  local first = backend.detect_auto_backend()

  package.loaded["telescope"] = nil
  package.loaded["telescope._extensions.ui-select"] = nil

  local second = backend.detect_auto_backend()

  package.loaded["telescope"] = saved_telescope
  package.loaded["telescope._extensions.ui-select"] = saved_telescope_ext
  package.loaded["fzf-lua"] = saved_fzf
  package.loaded["snacks.picker"] = saved_snacks

  expect.equality(first, "external")
  expect.equality(second, "external")
end

T["ui.select forwards kind to vim.ui.select when backend is vim"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local ui = require("tf-docs.ui")

  config.setup({ ui_select_backend = "vim" })

  local saved_select = vim.ui.select
  local observed
  vim.ui.select = function(items, opts, on_choice)
    observed = { items = items, opts = opts }
    on_choice(items[2])
  end

  local chosen
  ui.select({ "a", "b" }, {
    prompt = "Pick:",
    kind = ui.SELECT_KIND,
    format_item = function(item)
      return item
    end,
  }, function(item)
    chosen = item
  end)

  vim.ui.select = saved_select

  expect.equality(observed.items, { "a", "b" })
  expect.equality(observed.opts.kind, "tf-docs")
  expect.equality(observed.opts.prompt, "Pick:")
  expect.equality(chosen, "b")
end

T["ui.select vim backend bypasses external plugin detection"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local ui = require("tf-docs.ui")
  local backend = require("tf-docs.ui_backend")

  config.setup({ ui_select_backend = "vim" })
  backend._clear_cache_for_test()

  local saved_select = vim.ui.select
  local called = false
  vim.ui.select = function(items, _, on_choice)
    called = true
    on_choice(items[1])
  end

  local saved_detect = backend.detect_auto_backend
  backend.detect_auto_backend = function()
    error("detect_auto_backend should not run for the vim backend")
  end

  local ok = pcall(ui.select, { "only" }, {
    prompt = "Pick:",
    format_item = function(item)
      return item
    end,
  }, function() end)

  backend.detect_auto_backend = saved_detect
  vim.ui.select = saved_select

  expect.equality(ok, true)
  expect.equality(called, true)
end

T["ui backend detects fzf-lua through its ui_select provider"] = function()
  H.reset_state()
  local backend = require("tf-docs.ui_backend")

  local saved = {
    telescope = package.loaded["telescope"],
    ext = package.loaded["telescope._extensions.ui-select"],
    fzf = package.loaded["fzf-lua"],
    provider = package.loaded["fzf-lua.providers.ui_select"],
    snacks = package.loaded["snacks.picker"],
  }
  package.loaded["telescope"] = nil
  package.loaded["telescope._extensions.ui-select"] = nil
  package.loaded["snacks.picker"] = nil

  package.loaded["fzf-lua"] = {}
  package.loaded["fzf-lua.providers.ui_select"] = {
    is_registered = function()
      return false
    end,
  }
  backend._clear_cache_for_test()
  local unregistered = backend.detect_auto_backend()

  package.loaded["fzf-lua.providers.ui_select"] = {
    is_registered = function()
      return true
    end,
  }
  backend._clear_cache_for_test()
  local registered = backend.detect_auto_backend()

  package.loaded["telescope"] = saved.telescope
  package.loaded["telescope._extensions.ui-select"] = saved.ext
  package.loaded["fzf-lua"] = saved.fzf
  package.loaded["fzf-lua.providers.ui_select"] = saved.provider
  package.loaded["snacks.picker"] = saved.snacks
  backend._clear_cache_for_test()

  expect.equality(unregistered, "builtin")
  expect.equality(registered, "external")
end

return T
