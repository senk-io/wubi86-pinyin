-- "忘码"记忆
--
-- 用拼音（或学码模式）打出来的字词，说明当时想不起五笔码，记为薄弱项并累加次数；
-- 之后用五笔打出同一个字词，次数减一，减到 0 就移除。
-- 数据保存在 Rime 用户目录下的 wubi86_pinyin_weak.txt，每行：字词<TAB>次数。
-- 只记录上屏结果，不记录按键过程。

local M = {}

local MAX_COUNT = 9
local FILE_NAME = "wubi86_pinyin_weak.txt"

local weak = nil
local path = nil

local function load()
  if weak then return end
  weak = {}
  path = rime_api.get_user_data_dir() .. "/" .. FILE_NAME
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    local text, count = line:match("^([^\t]+)\t(%d+)$")
    if text then weak[text] = tonumber(count) end
  end
  f:close()
end

local function save()
  local f = io.open(path, "w")
  if not f then
    log.warning("wubi_memory: cannot write " .. path)
    return
  end
  local keys = {}
  for text in pairs(weak) do keys[#keys + 1] = text end
  table.sort(keys)
  for _, text in ipairs(keys) do
    f:write(text, "\t", weak[text], "\n")
  end
  f:close()
end

-- 返回某个字词的薄弱次数，没有记录时为 nil
function M.count(text)
  load()
  return weak[text]
end

-- 记录一次上屏；forgot 为真表示是用拼音打出来的
function M.record(text, forgot)
  load()
  local old = weak[text]
  if forgot then
    weak[text] = math.min((old or 0) + 1, MAX_COUNT)
  elseif old then
    weak[text] = old > 1 and old - 1 or nil
  else
    return
  end
  if weak[text] ~= old then save() end
end

return M
