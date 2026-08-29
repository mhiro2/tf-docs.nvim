local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

---@param fn fun(linked_module: string): any
---@return any
local function with_symlinked_module(fn)
  local linked_module = vim.fn.tempname()
  local target_module = H.fixture_path("workspace_scope", "modules", "network")
  local linked, link_error = vim.uv.fs_symlink(target_module, linked_module)
  if not linked then
    error(link_error)
  end

  local ok, result = pcall(fn, linked_module)
  vim.fn.delete(linked_module)
  if not ok then
    error(result)
  end
  return result
end

T["workspace root prefers the nearest marker directory over marker order"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { ".terraform.lock.hcl", "terraform.tf" } })
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_priority", "subdir", "main.tf")
  local got = H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.resolve_scopes(bufnr, config.get()).workspace_root
  end)

  expect.equality(got, H.fixture_path("root_priority", "subdir"))
end

T["workspace root falls back to an ancestor marker"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  config.setup({ root_markers = { "terraform.tf" } })
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_marker", "subdir", "foo.tf")
  local got = H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    return root.resolve_scopes(bufnr, config.get()).workspace_root
  end)

  expect.equality(got, H.fixture_path("root_marker"))
end

T["workspace discovery uses the current root marker configuration"] = function()
  H.reset_state()
  local plugin = require("tf-docs")
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_marker", "subdir", "foo.tf")
  H.with_scratch_buf({ name = file, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    plugin.setup({ root_markers = { "terraform.tf" } })
    local first = root.resolve_scopes(bufnr, config.get()).workspace_root
    expect.equality(first, H.fixture_path("root_marker"))

    plugin.setup({ root_markers = { ".terraform.lock.hcl" } })
    local second = root.resolve_scopes(bufnr, config.get()).workspace_root
    expect.equality(second, nil)
  end)
end

T["module directory follows the current buffer path"] = function()
  H.reset_state()
  local root = require("tf-docs.root")

  local file_a = H.fixture_path("root_marker", "subdir", "foo.tf")
  local file_b = H.fixture_path("root_priority", "subdir", "main.tf")
  H.with_scratch_buf({ name = file_a, lines = { "" }, cursor = { 1, 0 } }, function(bufnr)
    local first = root.get_module_dir(bufnr)
    expect.equality(first, H.fixture_path("root_marker", "subdir"))

    vim.api.nvim_buf_set_name(bufnr, file_b)
    local refreshed = root.get_module_dir(bufnr)
    expect.equality(refreshed, H.fixture_path("root_priority", "subdir"))
  end)
end

T["scope resolver receives the actual buffer and action opts take precedence"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  local file = H.fixture_path("root_marker", "subdir", "foo.tf")
  H.with_scratch_buf({ name = file, lines = { "" } }, function(bufnr)
    local callback_bufnr
    local callback_calls = 0
    config.setup({
      scope_resolver = function(resolved_bufnr)
        callback_calls = callback_calls + 1
        callback_bufnr = resolved_bufnr
        return {
          module_dir = "/configured/module",
          workspace_root = "/configured/workspace",
        }
      end,
    })

    local configured = root.resolve_scopes(0, config.get())
    expect.equality(callback_bufnr, bufnr)
    expect.equality(callback_calls, 1)
    expect.equality(configured.module_dir, "/configured/module")
    expect.equality(configured.workspace_root, "/configured/workspace")

    local explicit = root.resolve_scopes(bufnr, config.get(), {
      module_dir = "/explicit/module",
      workspace_root = "/explicit/workspace",
    })
    expect.equality(explicit.module_dir, "/explicit/module")
    expect.equality(explicit.workspace_root, "/explicit/workspace")
    expect.equality(callback_calls, 1)
  end)
end

T["scope resolver discovers workspace from an overridden module directory"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  local module_dir = H.fixture_path("workspace_scope", "modules", "network")
  config.setup({
    root_markers = { ".terraform.lock.hcl" },
    scope_resolver = function()
      return { module_dir = module_dir }
    end,
  })

  local scopes = root.resolve_scopes(0, config.get())
  expect.equality(scopes.module_dir, module_dir)
  expect.equality(scopes.workspace_root, H.fixture_path("workspace_scope"))
end

T["explicit symlinked module scope discovers its physical workspace"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")
  config.setup({ root_markers = { ".terraform.lock.hcl" } })

  with_symlinked_module(function(linked_module)
    local scopes = root.resolve_scopes(0, config.get(), { module_dir = linked_module })
    expect.equality(scopes.module_dir, linked_module)
    expect.equality(scopes.workspace_root, H.fixture_path("workspace_scope"))
  end)
end

T["scope callback symlinked module discovers its physical workspace"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")

  with_symlinked_module(function(linked_module)
    config.setup({
      root_markers = { ".terraform.lock.hcl" },
      scope_resolver = function()
        return { module_dir = linked_module }
      end,
    })

    local scopes = root.resolve_scopes(0, config.get())
    expect.equality(scopes.module_dir, linked_module)
    expect.equality(scopes.workspace_root, H.fixture_path("workspace_scope"))
  end)
end

T["workspace discovery retains fallback for a nonexistent module path"] = function()
  H.reset_state()
  local config = require("tf-docs.config")
  local root = require("tf-docs.root")
  config.setup({ root_markers = { ".terraform.lock.hcl" } })

  local missing_module = H.fixture_path("workspace_scope", "modules", "not-created")
  expect.equality(root.find_workspace_root(missing_module, config.get()), H.fixture_path("workspace_scope"))
end

return T
