local M = {}

function M.check()
  local health = vim.health or require("health")
  health.start("tf-docs")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10+ detected")
  else
    health.error("Neovim 0.10+ required")
  end

  if vim.ui and vim.ui.open then
    health.ok("vim.ui.open available")
  else
    health.error("vim.ui.open is unavailable")
  end

  local function has_ts_parser(lang)
    local patterns = {
      string.format("parser/%s.so", lang),
      string.format("parser/%s.dylib", lang),
      string.format("parser/%s.dll", lang),
      string.format("parser/%s.wasm", lang),
    }
    for _, p in ipairs(patterns) do
      local found = vim.api.nvim_get_runtime_file(p, true)
      if found and found[1] then
        return true
      end
    end
    return false
  end

  local has_parser = has_ts_parser("terraform") or has_ts_parser("hcl")

  if has_parser then
    health.ok("treesitter parser available (terraform/hcl)")
  else
    health.warn("treesitter parser not detected (terraform/hcl)")
  end
end

return M
