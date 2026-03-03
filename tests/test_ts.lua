local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

T["ts.get_context detects resource and anchor from key ="] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    '  ami = "ami-123"',
    "  tags = {",
    '    Name = "x"',
    "  }",
    "}",
  }
  local ctx = H.with_scratch_buf({ lines = lines, cursor = { 3, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["ts.get_context detects anchor from block {"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    "  lifecycle {",
    "    create_before_destroy = true",
    "  }",
    "}",
  }
  local ctx = H.with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "lifecycle")
end

T["ts.get_context extracts provider_hint from provider = google.foo"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "google_compute_instance" "x" {',
    "  provider = google.foo",
    "  labels = {",
    '    env = "dev"',
    "  }",
    "}",
  }
  local ctx = H.with_scratch_buf({ lines = lines, cursor = { 3, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "google_compute_instance")
  expect.equality(ctx.provider_hint, "google")
end

T["ts.get_context detects module and reads module source"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  source = "registry.terraform.io/terraform-aws-modules/vpc/aws"',
    "}",
  }
  local ctx = H.with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
    return ts.get_context(bufnr)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "registry.terraform.io/terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback ignores braces in strings/comments for module source"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  note = "}"',
    "  # comment with { brace should be ignored",
    '  source = "registry.terraform.io/terraform-aws-modules/vpc/aws"',
    "}",
  }
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = lines, cursor = { 4, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "registry.terraform.io/terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback works with large files"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {}
  for i = 1, 1200 do
    lines[#lines + 1] = ("# filler %d"):format(i)
  end
  lines[#lines + 1] = 'resource "aws_instance" "x" {'
  lines[#lines + 1] = "  tags = {"
  lines[#lines + 1] = '    Name = "x"'
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"

  local cursor_row = #lines - 3
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = lines, cursor = { cursor_row, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["ts.get_context supports explicit cursor argument"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    '  ami = "ami-123"',
    "  tags = {",
    '    Name = "x"',
    "  }",
    "}",
  }

  local ctx = H.with_scratch_buf({ lines = lines, cursor = { 1, 0 } }, function(bufnr)
    return ts.get_context(bufnr, { 3, 2 })
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["ts.get_context falls back when treesitter parser raises"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "x" {',
    "  tags = {",
    '    Name = "x"',
    "  }",
    "}",
  }

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          error("forced parser failure")
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_instance")
  expect.equality(ctx.anchor_candidate, "tags")
end

T["ts.get_context caches treesitter result for repeated calls"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local parse_calls = 0
  local tree = {
    root = function()
      return {
        named_descendant_for_range = function()
          return {
            range = function()
              return 0, 0, 4, 0
            end,
          }
        end,
      }
    end,
  }
  local parser = {
    parse = function()
      parse_calls = parse_calls + 1
      return { tree }
    end,
  }

  H.with_treesitter({
    get_parser = function()
      return parser
    end,
  }, function()
    H.with_scratch_buf({
      lines = {
        'resource "aws_instance" "x" {',
        "  tags = {}",
        "}",
      },
      cursor = { 2, 2 },
    }, function(bufnr)
      local first = ts.get_context(bufnr)
      local second = ts.get_context(bufnr)
      expect.equality(first.kind, "resource")
      expect.equality(second.kind, "resource")
    end)
  end)

  expect.equality(parse_calls, 1)
end

T["ts.get_context cache invalidates when buffer changedtick changes"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local parse_calls = 0
  local tree = {
    root = function()
      return {
        named_descendant_for_range = function()
          return {
            range = function()
              return 0, 0, 4, 0
            end,
          }
        end,
      }
    end,
  }
  local parser = {
    parse = function()
      parse_calls = parse_calls + 1
      return { tree }
    end,
  }

  H.with_treesitter({
    get_parser = function()
      return parser
    end,
  }, function()
    H.with_scratch_buf({
      lines = {
        'resource "aws_instance" "x" {',
        "  tags = {}",
        "}",
      },
      cursor = { 2, 2 },
    }, function(bufnr)
      ts.get_context(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '  tags = { Name = "x" }' })
      ts.get_context(bufnr)
    end)
  end)

  expect.equality(parse_calls, 2)
end

T["ts.list_resources returns all resources and data sources"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "web" {',
    '  ami = "ami-123"',
    "}",
    "",
    'data "aws_ami" "ubuntu" {',
    "  most_recent = true",
    "}",
    "",
    'module "vpc" {',
    '  source = "terraform-aws-modules/vpc/aws"',
    "}",
  }
  local resources = H.with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 3)
  expect.equality(resources[1].kind, "resource")
  expect.equality(resources[1].type, "aws_instance")
  expect.equality(resources[1].name, "web")
  expect.equality(resources[1].line, 1)
  expect.equality(resources[2].kind, "data")
  expect.equality(resources[2].type, "aws_ami")
  expect.equality(resources[2].name, "ubuntu")
  expect.equality(resources[2].line, 5)
  expect.equality(resources[3].kind, "module")
  expect.equality(resources[3].name, "vpc")
  expect.equality(resources[3].line, 9)
end

T["ts.list_resources returns empty table when no resources found"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    "# Just a comment",
    'variable "foo" {}',
  }
  local resources = H.with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 0)
end

return T
