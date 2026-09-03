local M = {}

---@alias TfDocsBlockKind "resource"|"data"|"ephemeral"|"action"|"list"|"module"
---@alias TfDocsCategory "resources"|"data-sources"|"ephemeral-resources"|"actions"|"list-resources"

local DOC_CATEGORIES = {
  resource = "resources",
  data = "data-sources",
  ephemeral = "ephemeral-resources",
  action = "actions",
  list = "list-resources",
}

---@param kind string|nil
---@return TfDocsCategory|nil
function M.docs_category(kind)
  return kind and DOC_CATEGORIES[kind] or nil
end

---@param kind string|nil
---@return boolean
function M.is_provider_backed(kind)
  return M.docs_category(kind) ~= nil
end

---@param kind string|nil
---@return boolean
function M.is_supported(kind)
  return kind == "module" or M.is_provider_backed(kind)
end

return M
