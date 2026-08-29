local M = {}

---@param path string
---@return string
function M.canonical_path(path)
  local normalized = vim.fs.normalize(path)
  local ok, resolved = pcall(vim.uv.fs_realpath, normalized)
  if ok and type(resolved) == "string" then
    return vim.fs.normalize(resolved)
  end

  -- A new buffer may name a file that does not exist yet. Resolve its parent
  -- so the buffer still matches a module reached through a symbolic link.
  local parent = vim.fs.dirname(normalized)
  if parent and parent ~= normalized then
    local ok_parent, resolved_parent = pcall(vim.uv.fs_realpath, parent)
    if ok_parent and type(resolved_parent) == "string" then
      return vim.fs.joinpath(vim.fs.normalize(resolved_parent), vim.fs.basename(normalized))
    end
  end
  return normalized
end

---@param bufnr number
---@return boolean
local function buffer_is_modified(bufnr)
  local ok, modified = pcall(vim.api.nvim_get_option_value, "modified", { buf = bufnr })
  return ok and modified == true
end

---@param time table|number|nil
---@return string
local function time_signature(time)
  if type(time) ~= "table" then
    return tostring(time or "")
  end
  return string.format("%s:%s", tostring(time.sec or time.tv_sec or ""), tostring(time.nsec or time.tv_nsec or ""))
end

---@param stat table
---@return string
local function stat_signature(stat)
  return table.concat({
    "file",
    tostring(stat.type or ""),
    tostring(stat.dev or ""),
    tostring(stat.ino or ""),
    tostring(stat.mode or ""),
    tostring(stat.size or ""),
    time_signature(stat.mtime),
    time_signature(stat.ctime),
  }, ":")
end

---@param path string
---@return number|nil
local function modified_buffer(path)
  local normalized = M.canonical_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and M.canonical_path(name) == normalized and buffer_is_modified(bufnr) then
        return bufnr
      end
    end
  end
  return nil
end

---@param module_dir string
---@return string[]
function M.modified_buffer_paths(module_dir)
  local normalized_dir = M.canonical_path(module_dir)
  local paths = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and buffer_is_modified(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local path = M.canonical_path(name)
        if vim.fs.dirname(path) == normalized_dir then
          paths[#paths + 1] = path
        end
      end
    end
  end
  return paths
end

---@param bufnr number
---@return string
local function buffer_signature(bufnr)
  return string.format("buffer:%d:%d", bufnr, vim.api.nvim_buf_get_changedtick(bufnr))
end

---@param path string
---@return string
function M.file_signature(path)
  local bufnr = modified_buffer(path)
  if bufnr then
    return buffer_signature(bufnr)
  end

  local ok, stat = pcall(vim.uv.fs_stat, path)
  if not ok or not stat then
    return "missing"
  end
  return stat_signature(stat)
end

---@param fd uv.fs_t
local function close_fd(fd)
  if fd ~= nil then
    pcall(vim.uv.fs_close, fd)
  end
end

---@param path string
---@return string|nil, string
function M.read_source(path)
  local bufnr = modified_buffer(path)
  if bufnr then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"), buffer_signature(bufnr)
  end

  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil, M.file_signature(path)
  end

  local ok_stat, stat = pcall(vim.uv.fs_fstat, fd)
  if not ok_stat or not stat or stat.type ~= "file" then
    close_fd(fd)
    return nil, stat and stat_signature(stat) or M.file_signature(path)
  end

  local ok_read, data = pcall(vim.uv.fs_read, fd, stat.size, 0)
  close_fd(fd)
  if not ok_read or type(data) ~= "string" then
    return nil, stat_signature(stat)
  end
  return data, stat_signature(stat)
end

return M
