local MiniTest = require("mini.test")

local M = {}

function M.run()
  MiniTest.setup()
  MiniTest.run({
    execute = { reporter = MiniTest.gen_reporter.stdout() },
  })
end

return M
