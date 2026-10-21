-- 五笔/拼音混输过滤器
--
-- 混输时同一段编码会同时出五笔候选和拼音候选，这里负责：
-- 1. 去噪（反引号学码模式下不过滤）：
--    - 拼音候选用到了简拼（只有声母的音节，如 adnt -> a d n t），多半是五笔码
--      被误当成拼音，丢掉；
--    - 输入码已经有五笔候选时，只匹配了输入前半段的拼音候选（adnt -> a -> 啊）
--      也是噪音，丢掉；
--    - 已经有完整匹配的拼音词时，同一输入的整句拼凑（如 nihao -> 你号）丢掉。
-- 2. emoji：开关 emoji 关闭时，丢掉纯 emoji 候选，不占候选位置。
-- 3. 编码提示（开关 code_hint）：
--    - 不是用五笔打出来的候选，注释里标出最短的五笔编码；
--    - 五笔候选如果是"忘码"记录里的字词，且当前输入还不是它的完整编码，
--      注释里标出完整编码和忘记次数，帮助记住。
-- 4. 忘码记录：上屏时交给 wubi_memory 记录，见该文件。
--
-- 配置（schema 中与 filter 同名的节点）：
--   dictionary: 用于反查的五笔码表名
--   lookup_prefix: 学码模式前缀，默认 "`"

local memory = require("wubi_memory")

local M = {}

local TABLE_TYPES = { table = true, user_table = true, completion = true }

local function is_from_pinyin(cand)
  return not TABLE_TYPES[cand:get_genuine().type]
end

local function on_commit(ctx)
  local segs = ctx.composition:toSegmentation():get_segments()
  for _, seg in ipairs(segs) do
    local cand = seg:get_selected_candidate()
    local status = seg.status
    if cand and (status == "kSelected" or status == "kConfirmed") then
      local text = cand.text
      if text:find("[\128-\255]") then  -- 只记录中文等非 ASCII 上屏
        memory.record(text, is_from_pinyin(cand))
      end
    end
  end
end

function M.init(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  env.reverse = ReverseLookup(config:get_string(ns .. "/dictionary") or "wubi86_jidian")
  env.prefix = config:get_string(ns .. "/lookup_prefix") or "`"
  env.commit_conn = env.engine.context.commit_notifier:connect(on_commit)
end

function M.fini(env)
  env.commit_conn:disconnect()
end

-- 最短的编码作为提示；同长的全部保留
local function shortest_codes(codes)
  local best, len = {}, math.huge
  for code in codes:gmatch("%S+") do
    if #code < len then
      best, len = { code }, #code
    elseif #code == len then
      best[#best + 1] = code
    end
  end
  return table.concat(best, " ")
end

local function has_code(codes, input, exact)
  for code in codes:gmatch("%S+") do
    if (exact and code == input) or (not exact and code:sub(1, #input) == input) then
      return true
    end
  end
  return false
end

local function syllable_length(preedit)
  return #preedit:gsub("[%s']", "")
end

-- preedit 形如 "a d n t" 或 "xi'an"；任何一个音节不含元音即为简拼
local function is_abbreviated(preedit)
  for syllable in preedit:gmatch("[^%s']+") do
    if not syllable:find("[aeiouvü]") then
      return true
    end
  end
  return false
end

-- 纯 emoji：每个字符都在 U+1F000 以上的符号区（不含 CJK 扩展区 U+20000 起）
local function is_emoji(text)
  for _, cp in utf8.codes(text) do
    if cp < 0x1F000 or cp >= 0x20000 then
      return false
    end
  end
  return true
end

function M.func(translation, env)
  local ctx = env.engine.context
  local hint_on = ctx:get_option("code_hint")
  local emoji_on = ctx:get_option("emoji")
  local seen_wubi, seen_full_phrase = false, false
  for cand in translation:iter() do
    local input = ctx.input:sub(cand.start + 1, cand._end)
    local lookup_mode = input:sub(1, #env.prefix) == env.prefix
    local code = lookup_mode and input:sub(#env.prefix + 1) or input
    local from_pinyin = is_from_pinyin(cand)
    local rest = #ctx.input:sub(cand.start + 1)
    local full = from_pinyin and syllable_length(cand.preedit) >= rest

    local noise = false
    if from_pinyin and not lookup_mode then
      noise = is_abbreviated(cand.preedit)
        or (seen_wubi and not full)
        or (seen_full_phrase and cand.type == "sentence")
    end
    if not emoji_on and is_emoji(cand.text) then
      noise = true
    end

    seen_wubi = seen_wubi or not from_pinyin
    seen_full_phrase = seen_full_phrase or (full and cand.type ~= "sentence")

    if not noise then
      if hint_on then
        local codes = env.reverse:lookup(cand.text)
        if codes ~= "" then
          if not has_code(codes, code, false) then
            cand:get_genuine().comment = "〔" .. shortest_codes(codes) .. "〕"
          else
            local forgot = memory.count(cand.text)
            if forgot and not has_code(codes, code, true) then
              cand:get_genuine().comment = "〔" .. shortest_codes(codes) .. " 忘" .. forgot .. "〕"
            end
          end
        end
      end
      yield(cand)
    end
  end
end

return M
