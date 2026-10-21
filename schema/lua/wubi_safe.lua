-- 附加功能的保护层：去噪、编码提示、忘码记录、顶字都不是输入法的基本功能，
-- 它们出任何错（代码缺陷、文件损坏、模块缺失）都只能让自己失效，不能让候选消失。
--
-- 过滤器里的 Lua 报错会中断整个候选列表，表现为"打字不出中文"。所以：
--   - 附加逻辑一律经 M.call 调用，出错返回 nil，调用方按"没有这项功能"处理；
--   - 附加模块一律经 M.require 加载，加载失败时换成什么都不做的空模块；
--   - yield 候选不放进 pcall，保证原有候选总能原样送出。
-- 同一处错误只记一次日志（Rime 日志目录的 ERROR 文件），不刷屏。

local M = {}

local reported = {}

local function report(name, err)
  if reported[name] then return end
  reported[name] = true
  local msg = "wubi86-pinyin: " .. name .. " disabled after error: " .. tostring(err)
  if log and log.error then pcall(log.error, msg) end
end

-- 调用 fn(...)，成功时原样返回它的结果，出错时返回 nil
function M.call(name, fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then
    report(name, result[2])
    return nil
  end
  return table.unpack(result, 2, result.n)
end

-- 任何字段都是空函数的模块
local function stub()
  return setmetatable({}, { __index = function() return function() end end })
end

function M.require(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then return mod end
  report("require " .. name, mod)
  return stub()
end

return M
