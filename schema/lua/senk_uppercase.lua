-- Shift+字母进入英文：大写字母直接上屏，不进入输入框，不出候选框；之后打的字母、数字、符号
-- 都原样直接上屏，直到按空格（空格也上屏）才回到中文。例如 Hello、iPhone15、U.S.。
-- - 正在输入时按 Shift+字母，先把当前选中的候选上屏，再上屏这个字母（wo 再按 Shift+A → 伙A）。
-- - 英文状态下按退格交给应用删字，不退出；按回车、Esc、方向键等其它非字符键时回到中文，按键照常处理。
-- - 英文模式（ascii_mode）和带 Control/Alt/Command 的组合键不处理，照常交给后面的组件。
-- SENK五笔、SENK拼音共用；出错时什么都不做，按键照常处理。

local kAccepted, kNoop = 1, 2

local XK_space = 0x20
local XK_BackSpace = 0xff08
-- Shift、Caps Lock 本身按下时不退出英文状态
local MODIFIERS = { [0xffe1] = true, [0xffe2] = true, [0xffe5] = true }

local M = {}

local function handle(key, env)
  if key:release() then return kNoop end
  local ctx = env.engine.context
  if ctx:get_option("ascii_mode") then
    env.english = false
    return kNoop
  end
  if key:ctrl() or key:alt() or key:super() then return kNoop end
  local code = key.keycode

  if env.english then
    if code == XK_space then
      env.english = false
      env.engine:commit_text(" ")
      return kAccepted
    end
    if code > XK_space and code < 0x7f then
      env.engine:commit_text(string.char(code))
      return kAccepted
    end
    if code ~= XK_BackSpace and not MODIFIERS[code] then env.english = false end
    return kNoop
  end

  if code < 0x41 or code > 0x5a then return kNoop end
  if ctx:is_composing() then ctx:commit() end
  env.engine:commit_text(string.char(code))
  env.english = true
  return kAccepted
end

function M.init(env)
  env.english = false
end

function M.func(key, env)
  local ok, result = pcall(handle, key, env)
  if ok then return result end
  env.english = false
  return kNoop
end

return M
