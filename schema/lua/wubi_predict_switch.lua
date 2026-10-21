-- 快捷键轮换联想用的资料文件夹（不用文件夹 → 文件夹 1 → 文件夹 2 → …）
-- 配置：wubi_predict/switch_key，默认 Control+Shift+R
-- 切换结果显示在之后联想候选的注释里，例如〔联想·笔记〕。

local predict = require("wubi_predict")

local kRejected, kAccepted, kNoop = 0, 1, 2

local M = {}

function M.init(env)
  local key = env.engine.schema.config:get_string("wubi_predict/switch_key") or "Control+Shift+R"
  env.switch_key = KeyEvent(key)
end

function M.func(key, env)
  if key:release() or not key:eq(env.switch_key) or not predict.available() then
    return kNoop
  end
  predict.next_profile()
  return kAccepted
end

return M
