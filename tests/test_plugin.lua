local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["setup rebuilds BufWritePost patterns on reconfigure"] = function()
  H.reset_state()
  local plugin = require("tf-docs")

  plugin.setup({ required_providers_files = { "versions.tf" } })
  local first_defs = vim.api.nvim_get_autocmds({ group = "tf-docs.nvim", event = "BufWritePost" })
  local first_patterns = {}
  for _, def in ipairs(first_defs) do
    if type(def.pattern) == "string" and def.pattern ~= "" then
      first_patterns[def.pattern] = true
    end
  end
  expect.equality(first_patterns["versions.tf"], true)
  expect.equality(first_patterns["providers.tf"], nil)
  expect.equality(first_patterns[".terraform.lock.hcl"], true)

  plugin.setup({ required_providers_files = { "providers.tf" } })
  local second_defs = vim.api.nvim_get_autocmds({ group = "tf-docs.nvim", event = "BufWritePost" })
  local second_patterns = {}
  for _, def in ipairs(second_defs) do
    if type(def.pattern) == "string" and def.pattern ~= "" then
      second_patterns[def.pattern] = true
    end
  end
  expect.equality(second_patterns["versions.tf"], nil)
  expect.equality(second_patterns["providers.tf"], true)
  expect.equality(second_patterns[".terraform.lock.hcl"], true)
end

T["TfDocOpen calls ui.open with resolved URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local opened_url
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/open", { url = "https://example.com/open" }
      end,
    },
    {
      target = ui,
      key = "open",
      value = function(url)
        opened_url = url
        return true
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocOpen" }, {})
  end)

  expect.equality(opened_url, "https://example.com/open")
end

T["TfDocCopyUrl calls ui.copy with resolved URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local copied_url
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/copy", { url = "https://example.com/copy" }
      end,
    },
    {
      target = ui,
      key = "copy",
      value = function(url)
        copied_url = url
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocCopyUrl" }, {})
  end)

  expect.equality(copied_url, "https://example.com/copy")
end

T["TfDocPeek passes trace to ui.peek"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local captured_trace
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/peek",
          {
            root = "/tmp/root",
            kind = "resource",
            type = "aws_instance",
            provider_source = "hashicorp/aws",
            provider_version = "5.0.0",
            url = "https://example.com/peek",
          }
      end,
    },
    {
      target = ui,
      key = "peek",
      value = function(trace)
        captured_trace = trace
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocPeek" }, {})
  end)

  expect.equality(captured_trace.url, "https://example.com/peek")
  expect.equality(captured_trace.kind, "resource")
end

T["TfDocDebug outputs trace fields"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local log = require("tf-docs.log")

  plugin.setup()

  local captured_level
  local captured_msg
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/debug",
          {
            root = "/tmp/root",
            kind = "data",
            type = "aws_ami",
            module_source = nil,
            provider_source = "hashicorp/aws",
            provider_version = "1.2.3",
            anchor = "tags",
            url = "https://example.com/debug",
            reason = nil,
          }
      end,
    },
    {
      target = log,
      key = "log_force",
      value = function(level, msg)
        captured_level = level
        captured_msg = msg
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocDebug" }, {})
  end)

  expect.equality(captured_level, "info")
  expect.equality(captured_msg:find("kind: data") ~= nil, true)
  expect.equality(captured_msg:find("url: https://example.com/debug") ~= nil, true)
end

T["TfDocList resolves selected item without moving cursor"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  plugin.setup()

  H.with_scratch_buf({
    lines = {
      'resource "aws_instance" "x" {',
      '  ami = "ami-123"',
      "}",
      'resource "aws_ami" "y" {',
      "}",
    },
    cursor = { 1, 0 },
  }, function()
    local cursor_before = vim.api.nvim_win_get_cursor(0)
    local opened_url
    local resolve_calls = 0

    H.with_patches({
      {
        target = ts,
        key = "list_resources",
        value = function()
          return {
            { kind = "resource", type = "aws_ami", name = "y", line = 4 },
          }
        end,
      },
      {
        target = ts,
        key = "get_context",
        value = function(_, cursor_pos)
          expect.equality(cursor_pos[1], 4)
          return { kind = "resource", type = "aws_ami", anchor_candidate = nil }
        end,
      },
      {
        target = resolver,
        key = "resolve",
        value = function(_, opts)
          resolve_calls = resolve_calls + 1
          expect.equality(opts.context.kind, "resource")
          expect.equality(opts.context.type, "aws_ami")
          return "https://example.com/docs", { url = "https://example.com/docs" }
        end,
      },
      {
        target = ui,
        key = "select",
        value = function(items, _, on_choice)
          on_choice(items[1])
        end,
      },
      {
        target = ui,
        key = "open",
        value = function(url)
          opened_url = url
          return true
        end,
      },
    }, function()
      vim.api.nvim_cmd({ cmd = "TfDocList" }, {})
    end)

    expect.equality(resolve_calls, 1)
    expect.equality(opened_url, "https://example.com/docs")
    expect.equality(vim.api.nvim_win_get_cursor(0), cursor_before)
  end)
end

T["TfDocList does not resolve when selection is cancelled"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  plugin.setup()

  H.with_scratch_buf({
    lines = {
      'resource "aws_instance" "x" {',
      "}",
    },
    cursor = { 1, 0 },
  }, function()
    local resolve_calls = 0
    local open_calls = 0

    H.with_patches({
      {
        target = ts,
        key = "list_resources",
        value = function()
          return {
            { kind = "resource", type = "aws_instance", name = "x", line = 1 },
          }
        end,
      },
      {
        target = ui,
        key = "select",
        value = function(_, _, on_choice)
          on_choice(nil)
        end,
      },
      {
        target = resolver,
        key = "resolve",
        value = function()
          resolve_calls = resolve_calls + 1
          return nil, { reason = "unexpected" }
        end,
      },
      {
        target = ui,
        key = "open",
        value = function()
          open_calls = open_calls + 1
          return true
        end,
      },
    }, function()
      vim.api.nvim_cmd({ cmd = "TfDocList" }, {})
    end)

    expect.equality(resolve_calls, 0)
    expect.equality(open_calls, 0)
  end)
end

T["TfDocClearCache clears cache and lockfile meta"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local cache = require("tf-docs.cache")
  local lockfile = require("tf-docs.lockfile")

  plugin.setup()

  local tmp_root = vim.fn.tempname()
  vim.fn.mkdir(tmp_root, "p")
  local lockfile_path = vim.fs.joinpath(tmp_root, ".terraform.lock.hcl")
  vim.fn.writefile({
    'provider "registry.terraform.io/hashicorp/aws" {',
    "  hashes = []",
    "}",
  }, lockfile_path)

  lockfile.resolve(tmp_root)
  cache.set_required(tmp_root, { aws = "hashicorp/aws" })
  cache.set_lockfile(tmp_root, { ["hashicorp/aws"] = "1.0.0" })
  cache.set_root(999, tmp_root)

  expect.equality(lockfile.get_meta(tmp_root)["hashicorp/aws"].version_missing, true)
  expect.equality(cache.get_required(tmp_root).aws, "hashicorp/aws")
  expect.equality(cache.get_lockfile(tmp_root)["hashicorp/aws"], "1.0.0")
  expect.equality(cache.get_root(999), tmp_root)

  vim.api.nvim_cmd({ cmd = "TfDocClearCache" }, {})

  expect.equality(cache.get_required(tmp_root), nil)
  expect.equality(cache.get_lockfile(tmp_root), nil)
  expect.equality(cache.get_root(999), nil)
  expect.equality(next(lockfile.get_meta(tmp_root)), nil)

  vim.fn.delete(tmp_root, "rf")
end

T["TfDocVersion passes resolved values to UI"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local lockfile = require("tf-docs.lockfile")
  local root = require("tf-docs.root")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local captured
  H.with_patches({
    {
      target = root,
      key = "get_root",
      value = function()
        return "/tmp/project"
      end,
    },
    {
      target = lockfile,
      key = "resolve",
      value = function(resolved_root)
        expect.equality(resolved_root, "/tmp/project")
        return { ["hashicorp/aws"] = "5.30.0" }
      end,
    },
    {
      target = lockfile,
      key = "get_meta",
      value = function(resolved_root)
        expect.equality(resolved_root, "/tmp/project")
        return { ["hashicorp/aws"] = {} }
      end,
    },
    {
      target = vim.uv,
      key = "fs_stat",
      value = function(path)
        expect.equality(path, "/tmp/project/.terraform.lock.hcl")
        return { type = "file" }
      end,
    },
    {
      target = ui,
      key = "show_versions",
      value = function(versions, resolved_root, meta, has_lockfile)
        captured = {
          versions = versions,
          root = resolved_root,
          meta = meta,
          has_lockfile = has_lockfile,
        }
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocVersion" }, {})
  end)

  expect.equality(captured.root, "/tmp/project")
  expect.equality(captured.versions["hashicorp/aws"], "5.30.0")
  expect.equality(captured.has_lockfile, true)
end

T["public API open() opens resolved URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local opened_url
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/api-open", { url = "https://example.com/api-open" }
      end,
    },
    {
      target = ui,
      key = "open",
      value = function(url)
        opened_url = url
        return true
      end,
    },
  }, function()
    plugin.open()
  end)

  expect.equality(opened_url, "https://example.com/api-open")
end

T["public API copy_url() copies resolved URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local copied_url
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/api-copy", { url = "https://example.com/api-copy" }
      end,
    },
    {
      target = ui,
      key = "copy",
      value = function(url)
        copied_url = url
      end,
    },
  }, function()
    plugin.copy_url()
  end)

  expect.equality(copied_url, "https://example.com/api-copy")
end

T["public API resolve() returns url and trace without opening or notifying"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")
  local log = require("tf-docs.log")

  plugin.setup()

  local open_calls = 0
  local log_calls = 0
  local url, trace
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/api-resolve", { url = "https://example.com/api-resolve", kind = "resource" }
      end,
    },
    {
      target = ui,
      key = "open",
      value = function()
        open_calls = open_calls + 1
        return true
      end,
    },
    {
      target = log,
      key = "log",
      value = function()
        log_calls = log_calls + 1
      end,
    },
  }, function()
    url, trace = plugin.resolve()
  end)

  expect.equality(url, "https://example.com/api-resolve")
  expect.equality(trace.kind, "resource")
  expect.equality(open_calls, 0)
  expect.equality(log_calls, 0)
end

T["public API clear_cache() clears cache and lockfile meta"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local cache = require("tf-docs.cache")
  local lockfile = require("tf-docs.lockfile")

  plugin.setup()

  cache.set_required("/tmp/api-root", { aws = "hashicorp/aws" })
  cache.set_root(998, "/tmp/api-root")
  expect.equality(cache.get_required("/tmp/api-root").aws, "hashicorp/aws")

  plugin.clear_cache()

  expect.equality(cache.get_required("/tmp/api-root"), nil)
  expect.equality(cache.get_root(998), nil)
  expect.equality(next(lockfile.get_meta("/tmp/api-root")), nil)
end

T["TfDocOpen maps unresolved reason to user-facing message"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local log = require("tf-docs.log")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local open_calls = 0
  local logs = {}
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return nil, { reason = "provider-unresolved" }
      end,
    },
    {
      target = ui,
      key = "open",
      value = function()
        open_calls = open_calls + 1
        return true
      end,
    },
    {
      target = log,
      key = "log",
      value = function(_, level, msg)
        table.insert(logs, { level = level, msg = msg })
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocOpen" }, {})
  end)

  expect.equality(open_calls, 0)
  expect.equality(#logs, 1)
  expect.equality(logs[1].level, "warn")
  expect.equality(logs[1].msg, "Unable to infer provider from resource/data type under cursor")
end

return T
