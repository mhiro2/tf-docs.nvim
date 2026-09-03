local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

---@param mutate fun(source_buf: number)
---@param expected_message string
local function expect_stale_list_abort(mutate, expected_message)
  H.reset_state()
  local log = require("tf-docs.log")
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local context_calls = 0
  local resolve_calls = 0
  local open_calls = 0
  local notifications = {}

  H.with_scratch_buf({
    lines = {
      'resource "aws_instance" "source" {',
      "}",
    },
  }, function(source_buf)
    H.with_scratch_buf({
      lines = {
        'resource "google_compute_instance" "other" {',
        "}",
      },
    }, function(other_buf)
      local selected
      local on_choice

      H.with_patches({
        {
          target = ts,
          key = "list_resources",
          value = function(bufnr)
            expect.equality(bufnr, source_buf)
            return {
              { kind = "resource", type = "aws_instance", name = "source", line = 1, col = 0 },
            }
          end,
        },
        {
          target = ts,
          key = "get_context",
          value = function()
            context_calls = context_calls + 1
            return { kind = "resource", type = "aws_instance", anchor_candidate = nil }
          end,
        },
        {
          target = resolver,
          key = "resolve",
          value = function()
            resolve_calls = resolve_calls + 1
            return "https://example.com/source", { url = "https://example.com/source" }
          end,
        },
        {
          target = ui,
          key = "select",
          value = function(items, _, callback)
            selected = items[1]
            on_choice = callback
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
          value = function(_, level, message)
            table.insert(notifications, { level = level, message = message })
          end,
        },
      }, function()
        vim.api.nvim_set_current_buf(source_buf)
        vim.api.nvim_cmd({ cmd = "TfDocList" }, {})
        expect.equality(type(on_choice), "function")

        vim.api.nvim_set_current_buf(other_buf)
        mutate(source_buf)
        on_choice(selected)
      end)
    end)
  end)

  expect.equality(context_calls, 0)
  expect.equality(resolve_calls, 0)
  expect.equality(open_calls, 0)
  expect.equality(notifications, { { level = "warn", message = expected_message } })
end

T["setup watches every Terraform source format and the dependency lockfile"] = function()
  H.reset_state()
  local plugin = require("tf-docs")

  plugin.setup()
  local definitions = vim.api.nvim_get_autocmds({ group = "tf-docs.nvim", event = "BufWritePost" })
  local patterns = {}
  for _, def in ipairs(definitions) do
    if type(def.pattern) == "string" and def.pattern ~= "" then
      patterns[def.pattern] = true
    end
  end
  expect.equality(patterns["*.tf"], true)
  expect.equality(patterns["*.tf.json"], true)
  expect.equality(patterns[".terraform.lock.hcl"], true)
end

T["public resolution keeps scopes and context keyed to concrete buffers"] = function()
  H.reset_state()
  local plugin = require("tf-docs")

  plugin.setup({ root_markers = { "terraform.tf" } })

  local first_file = H.fixture_path("root_marker", "subdir", "foo.tf")
  local second_file = H.fixture_path("root_priority", "subdir", "main.tf")
  local first_module = H.fixture_path("root_marker", "subdir")
  local first_workspace = H.fixture_path("root_marker")
  local second_module = H.fixture_path("root_priority", "subdir")
  local second_workspace = H.fixture_path("root_priority", "subdir")

  H.with_no_treesitter(function()
    H.with_scratch_buf({
      name = first_file,
      lines = {
        'resource "aws_instance" "first" {',
        '  ami = "ami-first"',
        "}",
      },
      cursor = { 2, 2 },
    }, function(first_buf)
      local _, first_trace = plugin.resolve()

      H.with_scratch_buf({
        name = second_file,
        lines = {
          'data "google_compute_image" "second" {',
          '  family = "debian"',
          "}",
        },
        cursor = { 2, 2 },
      }, function(second_buf)
        expect.equality(vim.api.nvim_buf_get_changedtick(first_buf), vim.api.nvim_buf_get_changedtick(second_buf))

        local _, second_trace = plugin.resolve(0)

        expect.equality(first_trace.module_dir, first_module)
        expect.equality(first_trace.workspace_root, first_workspace)
        expect.equality(first_trace.kind, "resource")
        expect.equality(first_trace.type, "aws_instance")
        expect.equality(second_trace.module_dir, second_module)
        expect.equality(second_trace.workspace_root, second_workspace)
        expect.equality(second_trace.kind, "data")
        expect.equality(second_trace.type, "google_compute_image")
      end)
    end)
  end)
end

T["buffer lifecycle autocmds invalidate only the event buffer context"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local ts = require("tf-docs.ts")

  plugin.setup()

  H.with_scratch_buf({}, function(first_buf)
    H.with_scratch_buf({}, function(second_buf)
      local context_clears = {}
      H.with_patches({
        {
          target = ts,
          key = "clear_buf_context",
          value = function(bufnr)
            table.insert(context_clears, bufnr)
          end,
        },
      }, function()
        vim.api.nvim_exec_autocmds("BufFilePost", { buffer = first_buf })
        vim.api.nvim_exec_autocmds("BufWipeout", { buffer = second_buf })
      end)

      expect.equality(context_clears, { first_buf, second_buf })
    end)
  end)
end

T["TfDocOpen calls ui.open with resolved URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local opened_url
  local expected_buf = vim.api.nvim_get_current_buf()
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(bufnr)
        expect.equality(bufnr, expected_buf)
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
  local expected_buf = vim.api.nvim_get_current_buf()
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(bufnr)
        expect.equality(bufnr, expected_buf)
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
  local expected_buf = vim.api.nvim_get_current_buf()
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(bufnr)
        expect.equality(bufnr, expected_buf)
        return "https://example.com/peek",
          {
            module_dir = "/tmp/root/module",
            workspace_root = "/tmp/root",
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
  local expected_buf = vim.api.nvim_get_current_buf()
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(bufnr)
        expect.equality(bufnr, expected_buf)
        return "https://example.com/debug",
          {
            module_dir = "/tmp/root/module",
            workspace_root = "/tmp/root",
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
  expect.equality(captured_msg:find("module directory: /tmp/root/module") ~= nil, true)
  expect.equality(captured_msg:find("workspace root: /tmp/root") ~= nil, true)
  expect.equality(captured_msg:find("kind: data") ~= nil, true)
  expect.equality(captured_msg:find("url: https://example.com/debug") ~= nil, true)
end

T["TfDocDebug uses the configured scope resolver"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local log = require("tf-docs.log")
  local ts = require("tf-docs.ts")

  local callback_bufnr
  plugin.setup({
    scope_resolver = function(bufnr)
      callback_bufnr = bufnr
      return {
        module_dir = "/tmp/debug-module",
        workspace_root = "/tmp/debug-workspace",
      }
    end,
  })

  local captured_msg
  H.with_patches({
    {
      target = ts,
      key = "get_context",
      value = function()
        return nil
      end,
    },
    {
      target = log,
      key = "log_force",
      value = function(_, msg)
        captured_msg = msg
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocDebug" }, {})
  end)

  expect.equality(callback_bufnr, vim.api.nvim_get_current_buf())
  expect.equality(captured_msg:find("module directory: /tmp/debug-module", 1, true) ~= nil, true)
  expect.equality(captured_msg:find("workspace root: /tmp/debug-workspace", 1, true) ~= nil, true)
end

T["public API list() propagates scopes without moving the cursor"] = function()
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
  }, function(bufnr)
    local cursor_before = vim.api.nvim_win_get_cursor(0)
    local opened_url
    local resolve_calls = 0

    H.with_patches({
      {
        target = ts,
        key = "list_resources",
        value = function()
          return {
            { kind = "resource", type = "aws_ami", name = "y", line = 4, col = 6 },
          }
        end,
      },
      {
        target = ts,
        key = "get_context",
        value = function(_, cursor_pos)
          expect.equality(cursor_pos[1], 4)
          expect.equality(cursor_pos[2], 6)
          return { kind = "resource", type = "aws_ami", anchor_candidate = nil }
        end,
      },
      {
        target = resolver,
        key = "resolve",
        value = function(_, opts)
          resolve_calls = resolve_calls + 1
          expect.equality(opts.module_dir, "/tmp/list-module")
          expect.equality(opts.workspace_root, "/tmp/list-workspace")
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
      plugin.list(bufnr, { module_dir = "/tmp/list-module", workspace_root = "/tmp/list-workspace" })
    end)

    expect.equality(resolve_calls, 1)
    expect.equality(opened_url, "https://example.com/docs")
    expect.equality(vim.api.nvim_win_get_cursor(0), cursor_before)
  end)
end

T["public API list() snapshots scopes across a delayed selection"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local registry = require("tf-docs.registry")
  local resolver = require("tf-docs.resolver")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  plugin.setup()

  H.with_scratch_buf({ lines = { 'resource "aws_instance" "x" {}' } }, function(source_bufnr)
    local caller_opts = {
      module_dir = "/tmp/original-module",
      workspace_root = "/tmp/original-workspace",
    }
    local delayed_choice
    local selected_item
    local switched_bufnr
    local opened_url
    local resolve_calls = 0
    local registry_calls = 0

    H.with_patches({
      {
        target = ts,
        key = "list_resources",
        value = function(bufnr)
          expect.equality(bufnr, source_bufnr)
          return { { kind = "resource", type = "aws_instance", name = "x", line = 1, col = 0 } }
        end,
      },
      {
        target = ts,
        key = "get_context",
        value = function(bufnr, cursor_pos)
          expect.equality(bufnr, source_bufnr)
          expect.equality(vim.api.nvim_get_current_buf(), switched_bufnr)
          expect.equality(cursor_pos, { 1, 0 })
          return { kind = "resource", type = "aws_instance" }
        end,
      },
      {
        target = resolver,
        key = "resolve",
        value = function(bufnr, opts)
          resolve_calls = resolve_calls + 1
          expect.equality(bufnr, source_bufnr)
          expect.equality(opts == caller_opts, false)
          expect.equality(opts.module_dir, "/tmp/original-module")
          expect.equality(opts.workspace_root, "/tmp/original-workspace")
          expect.equality(opts.context.type, "aws_instance")
          local fallback_url = "https://registry.terraform.io/providers/hashicorp/aws/5.0.0/docs/resources/instance"
          return fallback_url,
            {
              kind = "resource",
              type = "aws_instance",
              provider_source = "hashicorp/aws",
              provider_version = "5.0.0",
              url = fallback_url,
            }
        end,
      },
      {
        target = registry,
        key = "resolve_url",
        value = function(trace, fallback_url, on_done)
          registry_calls = registry_calls + 1
          expect.equality(vim.api.nvim_get_current_buf(), switched_bufnr)
          expect.equality(trace.provider_source, "hashicorp/aws")
          expect.equality(
            fallback_url,
            "https://registry.terraform.io/providers/hashicorp/aws/5.0.0/docs/resources/instance"
          )
          on_done("https://registry.terraform.io/providers/hashicorp/aws/5.0.0/docs/resources/aws_instance")
        end,
      },
      {
        target = ui,
        key = "select",
        value = function(items, _, on_choice)
          selected_item = items[1]
          delayed_choice = on_choice
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
      plugin.list(0, caller_opts)
      caller_opts.module_dir = "/tmp/mutated-module"
      caller_opts.workspace_root = "/tmp/mutated-workspace"

      H.with_scratch_buf({ lines = { "switched" } }, function(bufnr)
        switched_bufnr = bufnr
        delayed_choice(selected_item)
      end)
    end)

    expect.equality(resolve_calls, 1)
    expect.equality(registry_calls, 1)
    expect.equality(
      opened_url,
      "https://registry.terraform.io/providers/hashicorp/aws/5.0.0/docs/resources/aws_instance"
    )
  end)
end

T["TfDocList resolves its selection against the originating buffer"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  plugin.setup()

  H.with_scratch_buf({
    lines = {
      'resource "aws_instance" "source" {',
      "}",
    },
  }, function(source_buf)
    H.with_scratch_buf({
      lines = {
        'resource "google_compute_instance" "other" {',
        "}",
      },
    }, function(other_buf)
      local selected
      local on_choice
      local observed = {}
      local opened_url

      H.with_patches({
        {
          target = ts,
          key = "list_resources",
          value = function(bufnr)
            observed.list = bufnr
            return {
              { kind = "resource", type = "aws_instance", name = "source", line = 1, col = 0 },
            }
          end,
        },
        {
          target = ts,
          key = "get_context",
          value = function(bufnr, cursor_pos)
            observed.context = bufnr
            expect.equality(cursor_pos, { 1, 0 })
            return { kind = "resource", type = "aws_instance", anchor_candidate = nil }
          end,
        },
        {
          target = resolver,
          key = "resolve",
          value = function(bufnr, opts)
            observed.resolve = bufnr
            expect.equality(opts.context.type, "aws_instance")
            return "https://example.com/source", { url = "https://example.com/source" }
          end,
        },
        {
          target = ui,
          key = "select",
          value = function(items, _, callback)
            selected = items[1]
            on_choice = callback
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
        vim.api.nvim_set_current_buf(source_buf)
        vim.api.nvim_cmd({ cmd = "TfDocList" }, {})

        vim.api.nvim_set_current_buf(other_buf)
        on_choice(selected)
      end)

      expect.equality(observed.list, source_buf)
      expect.equality(observed.context, source_buf)
      expect.equality(observed.resolve, source_buf)
      expect.equality(opened_url, "https://example.com/source")
    end)
  end)
end

T["TfDocList aborts when the originating buffer is wiped while selecting"] = function()
  expect_stale_list_abort(function(source_buf)
    vim.api.nvim_buf_delete(source_buf, { force = true })
  end, "The Terraform buffer was closed while selecting; run :TfDocList again")
end

T["TfDocList aborts when the originating buffer changes while selecting"] = function()
  expect_stale_list_abort(function(source_buf)
    vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { 'resource "aws_instance" "changed" {' })
  end, "The Terraform buffer changed while selecting; run :TfDocList again")
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
            { kind = "resource", type = "aws_instance", name = "x", line = 1, col = 0 },
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

T["TfDocList uses the configured scope resolver"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local ts = require("tf-docs.ts")
  local ui = require("tf-docs.ui")

  local callback_count = 0
  plugin.setup({
    scope_resolver = function()
      callback_count = callback_count + 1
      return {
        module_dir = "/tmp/list-module",
        workspace_root = "/tmp/list-workspace",
      }
    end,
  })

  H.with_scratch_buf({ lines = { 'module "vpc" { source = "terraform-aws-modules/vpc/aws" }' } }, function()
    local opened_url
    H.with_patches({
      {
        target = ts,
        key = "list_resources",
        value = function()
          return { { kind = "module", name = "vpc", line = 1 } }
        end,
      },
      {
        target = ts,
        key = "get_context",
        value = function()
          return { kind = "module", module_source = "terraform-aws-modules/vpc/aws" }
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

    expect.equality(opened_url, "https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws")
  end)

  expect.equality(callback_count, 1)
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
  cache.set_required(tmp_root, { aws = "hashicorp/aws" }, "required-signature")
  cache.set_lockfile(tmp_root, { ["hashicorp/aws"] = "1.0.0" }, "lockfile-signature", {})

  expect.equality(lockfile.get_meta(tmp_root)["hashicorp/aws"].version_missing, true)
  expect.equality(cache.get_required(tmp_root, "required-signature").aws, "hashicorp/aws")
  expect.equality(cache.get_lockfile(tmp_root, "lockfile-signature")["hashicorp/aws"], "1.0.0")

  vim.api.nvim_cmd({ cmd = "TfDocClearCache" }, {})

  expect.equality(cache.get_required(tmp_root, "required-signature"), nil)
  expect.equality(cache.get_lockfile(tmp_root, "lockfile-signature"), nil)
  expect.equality(next(lockfile.get_meta(tmp_root)), nil)

  vim.fn.delete(tmp_root, "rf")
end

T["TfDocVersion passes resolved values to UI"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local lockfile = require("tf-docs.lockfile")
  local ui = require("tf-docs.ui")

  local callback_bufnr
  plugin.setup({
    scope_resolver = function(bufnr)
      callback_bufnr = bufnr
      return { workspace_root = "/tmp/project" }
    end,
  })

  local captured
  H.with_patches({
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
          workspace_root = resolved_root,
          meta = meta,
          has_lockfile = has_lockfile,
        }
      end,
    },
  }, function()
    vim.api.nvim_cmd({ cmd = "TfDocVersion" }, {})
  end)

  expect.equality(captured.workspace_root, "/tmp/project")
  expect.equality(captured.versions["hashicorp/aws"], "5.30.0")
  expect.equality(captured.has_lockfile, true)
  expect.equality(callback_bufnr, vim.api.nvim_get_current_buf())
end

T["public API open() propagates scopes and opens the Registry-corrected URL"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local registry = require("tf-docs.registry")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local opened_url
  local captured_bufnr
  local captured_opts
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(bufnr, opts)
        captured_bufnr = bufnr
        captured_opts = opts
        return "https://example.com/api-open", { url = "https://example.com/api-open", kind = "resource" }
      end,
    },
    {
      target = registry,
      key = "resolve_url",
      value = function(trace, fallback_url, on_done)
        expect.equality(trace.kind, "resource")
        expect.equality(fallback_url, "https://example.com/api-open")
        on_done("https://example.com/registry-corrected")
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
    plugin.open(42, { module_dir = "/tmp/module", workspace_root = "/tmp/workspace" })
  end)

  expect.equality(captured_bufnr, 42)
  expect.equality(captured_opts.module_dir, "/tmp/module")
  expect.equality(captured_opts.workspace_root, "/tmp/workspace")
  expect.equality(opened_url, "https://example.com/registry-corrected")
end

T["public API copy_url() propagates explicit scopes"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local copied_url
  local captured_opts
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(_, opts)
        captured_opts = opts
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
    plugin.copy_url(0, { module_dir = "/tmp/copy-module", workspace_root = "/tmp/copy-workspace" })
  end)

  expect.equality(copied_url, "https://example.com/api-copy")
  expect.equality(captured_opts.module_dir, "/tmp/copy-module")
  expect.equality(captured_opts.workspace_root, "/tmp/copy-workspace")
end

T["public API peek() propagates explicit scopes"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local captured_opts
  local captured_trace
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function(_, opts)
        captured_opts = opts
        return "https://example.com/api-peek", { url = "https://example.com/api-peek" }
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
    plugin.peek(0, { module_dir = "/tmp/peek-module", workspace_root = "/tmp/peek-workspace" })
  end)

  expect.equality(captured_opts.module_dir, "/tmp/peek-module")
  expect.equality(captured_opts.workspace_root, "/tmp/peek-workspace")
  expect.equality(captured_trace.url, "https://example.com/api-peek")
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

  cache.set_required("/tmp/api-root", { aws = "hashicorp/aws" }, "api-signature")
  expect.equality(cache.get_required("/tmp/api-root", "api-signature").aws, "hashicorp/aws")

  plugin.clear_cache()

  expect.equality(cache.get_required("/tmp/api-root", "api-signature"), nil)
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
  expect.equality(logs[1].msg, "Unable to infer provider from block type under cursor")
end

T["TfDocOpen still opens but notifies (info) when a version fallback is used"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local log = require("tf-docs.log")
  local resolver = require("tf-docs.resolver")
  local ui = require("tf-docs.ui")

  plugin.setup()

  local opened_url
  local logs = {}
  H.with_patches({
    {
      target = resolver,
      key = "resolve",
      value = function()
        return "https://example.com/fallback",
          { url = "https://example.com/fallback", reason = "lockfile-version-missing" }
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

  expect.equality(opened_url, "https://example.com/fallback")
  expect.equality(#logs, 1)
  expect.equality(logs[1].level, "info")
  expect.equality(logs[1].msg:find("fallback version") ~= nil, true)
end

return T
