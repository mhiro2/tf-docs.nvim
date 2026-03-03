local M = {}

---@alias TfDocsDetectedUIBackend "external"|"builtin"

local detected_backend ---@type TfDocsDetectedUIBackend|nil

---@return boolean
local function has_telescope_ui_select()
  local ok_telescope, _ = pcall(require, "telescope")
  if not ok_telescope then
    return false
  end
  local ok_ext, _ = pcall(require, "telescope._extensions.ui-select")
  return ok_ext
end

---@return boolean
local function has_fzf_ui_select()
  local ok_fzf, fzf = pcall(require, "fzf-lua")
  return ok_fzf and type(fzf) == "table" and fzf.registered_ui_select == true
end

---@return boolean
local function has_snacks_picker()
  local ok_snacks, _ = pcall(require, "snacks.picker")
  return ok_snacks
end

---@return TfDocsDetectedUIBackend
function M.detect_auto_backend()
  if detected_backend then
    return detected_backend
  end

  if has_telescope_ui_select() or has_fzf_ui_select() or has_snacks_picker() then
    detected_backend = "external"
  else
    detected_backend = "builtin"
  end
  return detected_backend
end

function M._clear_cache_for_test()
  detected_backend = nil
end

return M
