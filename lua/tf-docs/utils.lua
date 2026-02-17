local M = {}

---@param fd uv.fs_t
local function close_fd(fd)
  if fd ~= nil then
    pcall(vim.uv.fs_close, fd)
  end
end

---@param path string
---@return string|nil
function M.read_file(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil
  end

  local ok_stat, stat = pcall(vim.uv.fs_fstat, fd)
  if not ok_stat or not stat or stat.type ~= "file" then
    close_fd(fd)
    return nil
  end

  local ok_read, data = pcall(vim.uv.fs_read, fd, stat.size, 0)
  close_fd(fd)
  if not ok_read or type(data) ~= "string" then
    return nil
  end
  return data
end

return M
