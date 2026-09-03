local MiniTest = require("mini.test")
local H = require("tests.helpers")

local T = MiniTest.new_set()
local expect = MiniTest.expect

---@param node_type string
---@param range integer[]
---@param children table[]|nil
---@return table
local function ast_node(node_type, range, children)
  local node = { _children = children or {} }
  node.type = function()
    return node_type
  end
  node.range = function()
    return range[1], range[2], range[3], range[4]
  end
  node.named_child_count = function()
    return #node._children
  end
  node.named_child = function(_, index)
    return node._children[index + 1]
  end
  node.parent = function()
    return node._parent
  end
  node.has_error = function()
    return false
  end
  for _, child in ipairs(node._children) do
    child._parent = node
  end
  return node
end

---@param line string
---@param text string
---@param row number
---@param init number|nil
---@return integer[]
local function text_range(line, text, row, init)
  local start = assert(line:find(text, init or 1, true)) - 1
  return { row, start, row, start + #text }
end

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

T["ts.get_context detects additional provider-backed block kinds"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local cases = {
    { kind = "ephemeral", type = "aws_ssm_parameter" },
    { kind = "action", type = "aws_events_put_events" },
    { kind = "list", type = "aws_vpc" },
  }

  for _, case in ipairs(cases) do
    local lines = {
      string.format('%s "%s" "example" {', case.kind, case.type),
      "  provider = aws.west",
      "  config {",
      '    name = "example"',
      "  }",
      "}",
    }
    local ctx = H.with_scratch_buf({ lines = lines, cursor = { 4, 4 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)

    expect.equality(ctx.kind, case.kind)
    expect.equality(ctx.type, case.type)
    expect.equality(ctx.provider_hint, "aws")
    expect.equality(ctx.anchor_candidate, "name")
  end
end

T["ts.get_context recognizes additional kinds through Treesitter"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local line = 'action "aws_events_put_events" "publish" { provider = aws.west }'

  local block_type = ast_node("identifier", text_range(line, "action", 0))
  local type_label = ast_node("string_lit", text_range(line, '"aws_events_put_events"', 0))
  local name_label = ast_node("string_lit", text_range(line, '"publish"', 0))
  local provider_name = ast_node("identifier", text_range(line, "provider", 0))
  local expression = ast_node("expression", text_range(line, "aws.west", 0))
  local attribute = ast_node("attribute", { 0, 43, 0, #line - 2 }, { provider_name, expression })
  local body = ast_node("body", { 0, 43, 0, #line - 2 }, { attribute })
  local block = ast_node("block", { 0, 0, 0, #line }, { block_type, type_label, name_label, body })
  local root_body = ast_node("body", { 0, 0, 0, #line }, { block })
  local root = ast_node("config_file", { 0, 0, 0, #line }, { root_body })
  root.named_descendant_for_range = function()
    return provider_name
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = { line }, cursor = { 1, 45 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "action")
  expect.equality(ctx.type, "aws_events_put_events")
  expect.equality(ctx.provider_hint, "aws")
end

T["ts.get_context Treesitter keeps an action attribute as the anchor"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_route53_resolver_firewall_rule" "example" {',
    '  action = "BLOCK"',
    "}",
  }

  local attribute_name = ast_node("identifier", text_range(lines[2], "action", 1))
  local expression = ast_node("expression", text_range(lines[2], '"BLOCK"', 1))
  local attribute = ast_node("attribute", { 1, 2, 1, #lines[2] }, { attribute_name, expression })
  local block_type = ast_node("identifier", text_range(lines[1], "resource", 0))
  local type_label = ast_node("string_lit", text_range(lines[1], '"aws_route53_resolver_firewall_rule"', 0))
  local name_label = ast_node("string_lit", text_range(lines[1], '"example"', 0))
  local resource_body = ast_node("body", { 1, 0, 1, #lines[2] }, { attribute })
  local resource = ast_node("block", { 0, 0, 2, 1 }, { block_type, type_label, name_label, resource_body })
  local root_body = ast_node("body", { 0, 0, 2, 1 }, { resource })
  local root = ast_node("config_file", { 0, 0, 2, 1 }, { root_body })
  root.named_descendant_for_range = function()
    return attribute_name
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = lines, cursor = { 2, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_route53_resolver_firewall_rule")
  expect.equality(ctx.anchor_candidate, "action")
end

T["ts.get_context Treesitter keeps a nested action block as the anchor"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_wafv2_web_acl" "example" {',
    "  rule {",
    "    action {",
    "      block {}",
    "    }",
    "  }",
    "}",
  }

  local action_type = ast_node("identifier", text_range(lines[3], "action", 2))
  local action_body = ast_node("body", { 2, 11, 4, 5 })
  local action_block = ast_node("block", { 2, 4, 4, 5 }, { action_type, action_body })
  local rule_type = ast_node("identifier", text_range(lines[2], "rule", 1))
  local rule_body = ast_node("body", { 1, 8, 5, 3 }, { action_block })
  local rule_block = ast_node("block", { 1, 2, 5, 3 }, { rule_type, rule_body })
  local block_type = ast_node("identifier", text_range(lines[1], "resource", 0))
  local type_label = ast_node("string_lit", text_range(lines[1], '"aws_wafv2_web_acl"', 0))
  local name_label = ast_node("string_lit", text_range(lines[1], '"example"', 0))
  local resource_body = ast_node("body", { 0, 41, 6, 1 }, { rule_block })
  local resource = ast_node("block", { 0, 0, 6, 1 }, { block_type, type_label, name_label, resource_body })
  local root_body = ast_node("body", { 0, 0, 6, 1 }, { resource })
  local root = ast_node("config_file", { 0, 0, 6, 1 }, { root_body })
  root.named_descendant_for_range = function()
    return action_type
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = lines, cursor = { 3, 4 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.type, "aws_wafv2_web_acl")
  expect.equality(ctx.anchor_candidate, "action")
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

T["ts.get_context treesitter accepts comments inside a provider traversal"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "google_compute_instance" "x" {',
    "  provider = alt /* keep the traversal root */ .west",
    "}",
  }

  local block_type = ast_node("identifier", text_range(lines[1], "resource", 0))
  local type_label = ast_node("string_lit", text_range(lines[1], '"google_compute_instance"', 0))
  local name_label = ast_node("string_lit", text_range(lines[1], '"x"', 0))
  local provider_name = ast_node("identifier", text_range(lines[2], "provider", 1))
  local expression = ast_node("expression", text_range(lines[2], "alt /* keep the traversal root */ .west", 1))
  local attribute = ast_node("attribute", { 1, 2, 1, #lines[2] }, { provider_name, expression })
  local resource_body = ast_node("body", { 1, 0, 1, #lines[2] }, { attribute })
  local block = ast_node("block", { 0, 0, 2, 1 }, { block_type, type_label, name_label, resource_body })
  local root_body = ast_node("body", { 0, 0, 2, 1 }, { block })
  local root = ast_node("config_file", { 0, 0, 2, 1 }, { root_body })
  root.named_descendant_for_range = function()
    return provider_name
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = lines, cursor = { 2, 4 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.provider_hint, "alt")
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

T["ts.get_context reads one-line module source from treesitter attribute nodes"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local line = 'module /* header comment */ "vpc" { source = "terraform-aws-modules/vpc/aws" }'

  local block_type = ast_node("identifier", text_range(line, "module", 0))
  local label = ast_node("string_lit", text_range(line, '"vpc"', 0))
  local source_range = text_range(line, "source", 0)
  local attribute_name = ast_node("identifier", source_range)
  local expression = ast_node("expression", text_range(line, '"terraform-aws-modules/vpc/aws"', 0))
  local attribute = ast_node("attribute", { 0, source_range[2], 0, #line - 2 }, { attribute_name, expression })
  local module_body = ast_node("body", { 0, source_range[2], 0, #line - 2 }, { attribute })
  local block = ast_node("block", { 0, 0, 0, #line }, { block_type, label, module_body })
  local root_body = ast_node("body", { 0, 0, 0, #line }, { block })
  local root = ast_node("config_file", { 0, 0, 0, #line }, { root_body })
  root.named_descendant_for_range = function()
    return attribute_name
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = { line }, cursor = { 1, source_range[2] } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "terraform-aws-modules/vpc/aws")
  expect.equality(ctx.module_source_reason, nil)
end

T["ts.get_context treesitter reads source only from the module body"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  # source = "github.com/comment/fake"',
    '  settings { source = "github.com/nested/fake" }',
    '  source = "terraform-aws-modules/vpc/aws"',
    "}",
  }

  local fake_name = ast_node("identifier", text_range(lines[3], "source", 2))
  local fake_expression = ast_node("expression", text_range(lines[3], '"github.com/nested/fake"', 2))
  local fake_attribute = ast_node("attribute", { 2, 13, 2, #lines[3] - 2 }, { fake_name, fake_expression })
  local nested_body = ast_node("body", { 2, 13, 2, #lines[3] - 2 }, { fake_attribute })
  local nested_type = ast_node("identifier", text_range(lines[3], "settings", 2))
  local nested_block = ast_node("block", { 2, 2, 2, #lines[3] }, { nested_type, nested_body })
  local comment = ast_node("comment", { 1, 2, 1, #lines[2] })
  local source_name = ast_node("identifier", text_range(lines[4], "source", 3))
  local source_expression = ast_node("expression", text_range(lines[4], '"terraform-aws-modules/vpc/aws"', 3))
  local source_attribute = ast_node("attribute", { 3, 2, 3, #lines[4] }, { source_name, source_expression })
  local module_body = ast_node("body", { 1, 0, 3, #lines[4] }, { comment, nested_block, source_attribute })
  local block_type = ast_node("identifier", text_range(lines[1], "module", 0))
  local label = ast_node("string_lit", text_range(lines[1], '"vpc"', 0))
  local block = ast_node("block", { 0, 0, 4, 1 }, { block_type, label, module_body })
  local root_body = ast_node("body", { 0, 0, 4, 1 }, { block })
  local root = ast_node("config_file", { 0, 0, 4, 1 }, { root_body })
  root.named_descendant_for_range = function()
    return fake_name
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({ lines = lines, cursor = { 3, 16 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "terraform-aws-modules/vpc/aws")
end

T["ts.get_context does not fallback after a successful treesitter parse without context"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local root = ast_node("config_file", { 0, 0, 2, 0 })
  root.named_descendant_for_range = function()
    return root
  end

  local ctx = H.with_treesitter({
    get_parser = function()
      return {
        parse = function()
          return {
            {
              root = function()
                return root
              end,
            },
          }
        end,
      }
    end,
  }, function()
    return H.with_scratch_buf({
      lines = { 'resource "aws_instance" "would_be_a_fallback_match" {', "}" },
      cursor = { 1, 10 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx, nil)
end

T["ts.get_context falls back when the treesitter root contains syntax errors"] = function()
  local ts = require("tf-docs.ts")
  local cases = {
    {
      lines = { 'resource "aws_instance" "unclosed" {', "  tags =" },
      cursor = { 2, 2 },
      expected_type = "aws_instance",
    },
    {
      lines = { "}", 'data "aws_ami" "after_extra_close" { filter = "ubuntu" }' },
      cursor = { 2, 10 },
      expected_type = "aws_ami",
    },
    {
      lines = { 'resource "google_compute_instance" "broken" {', "  invalid = (", "  provider = google.west", "}" },
      cursor = { 3, 4 },
      expected_type = "google_compute_instance",
    },
  }

  for _, case in ipairs(cases) do
    H.reset_state()
    local parse_calls = 0
    local root = ast_node("config_file", { 0, 0, #case.lines - 1, #(case.lines[#case.lines] or "") })
    root.has_error = function()
      return true
    end
    root.named_descendant_for_range = function()
      error("an erroneous root must not be queried for context")
    end

    local ctx = H.with_treesitter({
      get_parser = function()
        return {
          parse = function()
            parse_calls = parse_calls + 1
            return {
              {
                root = function()
                  return root
                end,
              },
            }
          end,
        }
      end,
    }, function()
      return H.with_scratch_buf({ lines = case.lines, cursor = case.cursor }, function(bufnr)
        return ts.get_context(bufnr)
      end)
    end)

    expect.equality(parse_calls, 1)
    expect.equality(ctx.kind == "resource" or ctx.kind == "data", true)
    expect.equality(ctx.type, case.expected_type)
  end
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
  local fallback_state
  local ctx = H.with_no_treesitter(function(state)
    fallback_state = state
    return H.with_scratch_buf({ lines = lines, cursor = { 4, 2 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(fallback_state.get_parser_calls > 0, true)
  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "registry.terraform.io/terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback reads only a direct static module source"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'module "vpc" {',
    '  # source = "github.com/comment/fake"',
    "  /*",
    '  source = "github.com/block-comment/fake"',
    "  */",
    "  settings = {",
    '    source = "github.com/nested/fake"',
    "  }",
    "  note = <<-EOT",
    'source = "github.com/heredoc/fake"',
    "}",
    "EOT",
    '  source = "terraform-aws-modules/vpc/aws"',
    "}",
  }

  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = lines, cursor = { 13, 4 } }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "terraform-aws-modules/vpc/aws")
  expect.equality(ctx.module_source_reason, nil)
end

T["ts.get_context fallback does not truncate a module source expression"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({
      lines = {
        'module "vpc" {',
        '  source = "terraform-aws-modules/vpc/aws" != "" ? local.primary : local.secondary',
        "}",
      },
      cursor = { 2, 4 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.module_source, nil)
  expect.equality(ctx.module_source_reason, "module-source-expression")
end

T["ts.get_context fallback supports one-line blocks"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({
      lines = {
        "module /* header",
        'comment */ "vpc" { source = "terraform-aws-modules/vpc/aws" }',
      },
      cursor = { 2, 20 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, "terraform-aws-modules/vpc/aws")
end

T["ts.get_context fallback accepts trivia between headers and direct attributes"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    "module # header comment",
    '  "vpc"',
    "{",
    "  source # attribute comment",
    "  /* before equals */ =",
    '  "terraform-aws-modules/vpc/aws"',
    "}",
    "",
    "resource",
    "/* header comment */",
    '  "google_compute_instance"',
    '  "x"',
    "{",
    "  provider",
    "  = alt /* traversal comment */",
    "  .west",
    "}",
  }

  local fallback_state
  local result = H.with_no_treesitter(function(state)
    fallback_state = state
    return H.with_scratch_buf({ lines = lines }, function(bufnr)
      return {
        module = ts.get_context(bufnr, { 6, 2 }),
        resource = ts.get_context(bufnr, { 16, 4 }),
      }
    end)
  end)

  expect.equality(fallback_state.get_parser_calls > 0, true)
  expect.equality(result.module.kind, "module")
  expect.equality(result.module.module_source, "terraform-aws-modules/vpc/aws")
  expect.equality(result.resource.kind, "resource")
  expect.equality(result.resource.type, "google_compute_instance")
  expect.equality(result.resource.provider_hint, "alt")
end

T["ts.get_context fallback uses columns for adjacent one-line blocks"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local line = '  resource "aws_instance" "first" { ami = "x" }   data "aws_ami" "second" { filter = "y" }  # tail'
  local first_inside = assert(line:find("ami =", 1, true)) - 1
  local second_inside = assert(line:find("filter =", 1, true)) - 1
  local first_close = assert(line:find("}", 1, true)) - 1
  local second_close = assert(line:find("}", first_close + 2, true)) - 1

  local result = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = { line } }, function(bufnr)
      return {
        before = ts.get_context(bufnr, { 1, 0 }),
        first = ts.get_context(bufnr, { 1, first_inside }),
        between = ts.get_context(bufnr, { 1, first_close + 1 }),
        second = ts.get_context(bufnr, { 1, second_inside }),
        after = ts.get_context(bufnr, { 1, second_close + 1 }),
        listed = ts.list_resources(bufnr),
      }
    end)
  end)

  expect.equality(result.before, nil)
  expect.equality(result.first.kind, "resource")
  expect.equality(result.first.type, "aws_instance")
  expect.equality(result.first.anchor_candidate, "ami")
  expect.equality(result.between, nil)
  expect.equality(result.second.kind, "data")
  expect.equality(result.second.type, "aws_ami")
  expect.equality(result.second.anchor_candidate, "filter")
  expect.equality(result.after, nil)
  expect.equality(#result.listed, 2)
  expect.equality(result.listed[1].col, 2)
  expect.equality(result.listed[2].col, assert(line:find("data", 1, true)) - 1)
end

T["ts.get_context fallback rejects module source expressions explicitly"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({
      lines = { 'module "vpc" {', "  source = local.vpc_source", "}" },
      cursor = { 2, 4 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "module")
  expect.equality(ctx.module_source, nil)
  expect.equality(ctx.module_source_reason, "module-source-expression")
end

T["ts.get_context fallback ignores provider references in comments strings and heredocs"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({
      lines = {
        'resource "google_compute_instance" "x" {',
        '  note = "provider = aws.string_fake"',
        "  # provider = aws.line_comment_fake",
        "  /*",
        "  provider = aws.block_comment_fake",
        "  */",
        "  note = <<EOT",
        "provider = aws.fake",
        "EOT",
        "  provider = google.real",
        "}",
      },
      cursor = { 10, 4 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx.kind, "resource")
  expect.equality(ctx.provider_hint, "google")
end

T["ts scanner ends indented heredocs at tab-indented delimiters"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_instance" "first" {',
    "  user_data = <<-EOT",
    'resource "fake" "inside_heredoc" {}',
    "\tEOT",
    "}",
    'data "aws_ami" "after_heredoc" {',
    '  filter = "ubuntu"',
    "}",
  }

  local result = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = lines }, function(bufnr)
      return {
        context = ts.get_context(bufnr, { 7, 2 }),
        listed = ts.list_resources(bufnr),
      }
    end)
  end)

  expect.equality(result.context.kind, "data")
  expect.equality(result.context.type, "aws_ami")
  expect.equality(#result.listed, 2)
  expect.equality(result.listed[2].name, "after_heredoc")
end

T["ts.get_context fallback returns nil outside the preceding block"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local ctx = H.with_no_treesitter(function()
    return H.with_scratch_buf({
      lines = { 'resource "aws_instance" "x" {', "}", "", 'output "id" { value = 1 }' },
      cursor = { 4, 4 },
    }, function(bufnr)
      return ts.get_context(bufnr)
    end)
  end)

  expect.equality(ctx, nil)
end

T["ts.get_context fallback keeps action attributes and nested blocks as anchors"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'resource "aws_route53_resolver_firewall_rule" "example" {',
    '  action = "BLOCK"',
    "}",
    "",
    'resource "aws_wafv2_web_acl" "example" {',
    "  rule {",
    "    action {",
    "      block {}",
    "    }",
    "  }",
    "}",
  }

  local contexts = H.with_no_treesitter(function()
    return H.with_scratch_buf({ lines = lines }, function(bufnr)
      return {
        attribute = ts.get_context(bufnr, { 2, 2 }),
        nested_block = ts.get_context(bufnr, { 7, 4 }),
      }
    end)
  end)

  expect.equality(contexts.attribute.anchor_candidate, "action")
  expect.equality(contexts.nested_block.anchor_candidate, "action")
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
        has_error = function()
          return false
        end,
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
        has_error = function()
          return false
        end,
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

T["ts.clear_buf_context drops only the given buffer's cached context"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local parse_calls = 0
  local tree = {
    root = function()
      return {
        has_error = function()
          return false
        end,
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
      ts.clear_buf_context(bufnr)
      ts.get_context(bufnr)
    end)
  end)

  -- The second call re-parses because the buffer's cache entry was cleared.
  expect.equality(parse_calls, 2)
end

T["ts.clear_context_cache drops all cached contexts"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local parse_calls = 0
  local tree = {
    root = function()
      return {
        has_error = function()
          return false
        end,
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
      ts.clear_context_cache()
      ts.get_context(bufnr)
    end)
  end)

  expect.equality(parse_calls, 2)
end

T["ts.list_resources returns all supported blocks"] = function()
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
    "",
    'ephemeral "aws_ssm_parameter" "secret" {}',
    'action "aws_events_put_events" "publish" {}',
    'list "aws_vpc" "existing" { provider = aws }',
  }
  local resources = H.with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 6)
  expect.equality(resources[1].kind, "resource")
  expect.equality(resources[1].type, "aws_instance")
  expect.equality(resources[1].name, "web")
  expect.equality(resources[1].line, 1)
  expect.equality(resources[1].col, 0)
  expect.equality(resources[2].kind, "data")
  expect.equality(resources[2].type, "aws_ami")
  expect.equality(resources[2].name, "ubuntu")
  expect.equality(resources[2].line, 5)
  expect.equality(resources[2].col, 0)
  expect.equality(resources[3].kind, "module")
  expect.equality(resources[3].name, "vpc")
  expect.equality(resources[3].line, 9)
  expect.equality(resources[3].col, 0)
  expect.equality(resources[4].kind, "ephemeral")
  expect.equality(resources[4].type, "aws_ssm_parameter")
  expect.equality(resources[4].name, "secret")
  expect.equality(resources[4].line, 13)
  expect.equality(resources[5].kind, "action")
  expect.equality(resources[5].type, "aws_events_put_events")
  expect.equality(resources[5].name, "publish")
  expect.equality(resources[5].line, 14)
  expect.equality(resources[6].kind, "list")
  expect.equality(resources[6].type, "aws_vpc")
  expect.equality(resources[6].name, "existing")
  expect.equality(resources[6].line, 15)
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

T["ts.list_resources ignores false headers and accepts a comment-split header"] = function()
  H.reset_state()
  local ts = require("tf-docs.ts")
  local lines = {
    'description = "resource \\"fake\\" \\"string\\" { }"',
    'template = "${format("resource \\"fake_template\\" \\"x\\" {", var.value)}"',
    "/*",
    'data "fake_comment" "x" {}',
    "*/",
    "locals {",
    "  rendered = <<EOT",
    "  EOT",
    'module "fake_heredoc" { source = "fake/fake/fake" }',
    "EOT",
    '  resource "nested" "invalid_terraform" {}',
    "}",
    "module # comments are trivia between header tokens",
    '"comment_split" { source = "fake/fake/fake" }',
    'resource "aws_instance" "real" {}',
  }

  local resources = H.with_scratch_buf({ lines = lines }, function(bufnr)
    return ts.list_resources(bufnr)
  end)

  expect.equality(#resources, 2)
  expect.equality(resources[1].kind, "module")
  expect.equality(resources[1].name, "comment_split")
  expect.equality(resources[1].line, 13)
  expect.equality(resources[2].kind, "resource")
  expect.equality(resources[2].type, "aws_instance")
  expect.equality(resources[2].name, "real")
  expect.equality(resources[2].line, 15)
end

return T
