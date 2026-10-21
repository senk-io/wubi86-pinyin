-- 快捷键轮换资料文件夹（不用文件夹 → 文件夹 1 → 文件夹 2 → …），也就是切换项目术语库
-- 配置：wubi_predict/switch_key，默认 Control+Shift+R
-- 切换结果显示在之后术语候选的注释里，例如〔术语·星辰〕。

local safe = require("wubi_safe")
local predict = safe.require("wubi_predict")

local kNoop, kAccepted = 2, 1

local M = {}

-- 字母键归一成大写：按住 Control 时鼠须管可能报控制字符（Ctrl+R → 0x12），按住 Shift 时大小写也不一定
local function letter(code)
  if code >= 0x61 and code <= 0x7a then return code - 0x20 end
  if code >= 0x01 and code <= 0x1a then return code + 0x40 end
  return code
end

-- 只比较 Control/Shift/Alt/Command 和键本身，不受大小写锁定等影响
local function same_key(a, b)
  return a:ctrl() == b:ctrl() and a:shift() == b:shift() and a:alt() == b:alt()
    and a:super() == b:super() and letter(a.keycode) == letter(b.keycode)
end

function M.init(env)
  env.switch_key = safe.call("switch init", function()
    return KeyEvent(env.engine.schema.config:get_string("wubi_predict/switch_key") or "Control+Shift+R")
  end)
end

local function switch(key, env)
  if key:release() or not env.switch_key or not same_key(key, env.switch_key)
    or not predict.available() then
    return false
  end
  predict.next_profile()
  return true
end

-- 出错时不吃掉按键
function M.func(key, env)
  return safe.call("switch", switch, key, env) and kAccepted or kNoop
end

return M
