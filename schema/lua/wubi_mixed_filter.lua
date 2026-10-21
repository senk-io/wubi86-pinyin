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
--      注释里标出完整编码和忘记次数，帮助记住；
--    - 用全码打出的字词如果有更短的简码（一级、二级、三级简码），注释里标出简码，
--      如 wqiy -> 你〔简 wq〕（配置 short_hint，默认开）。
-- 4. 忘码记录：上屏时交给 wubi_memory 记录，见该文件。
-- 5. 项目术语（开关 terms，默认开）：当前资料文件夹的术语里，五笔词码、全拼或拼音首字母
--    以当前输入码开头的，插在第 2 位起，见 wubi_predict.lua。
-- 6. 续写联想（开关 predict，默认关）：上屏时把上文交给 wubi_predict；打下一个词时，
--    匹配当前输入码的联想词同样插在第 2 位起。
--
-- 配置（schema 中与 filter 同名的节点）：
--   dictionary: 用于反查的五笔码表名
--   pinyin_dictionary: 用于给联想词注音的拼音词库
--   lookup_prefix: 学码模式前缀，默认 "`"
--   short_hint: 全码打出时是否提示简码，默认 true
--   term_max: 每次最多插入几个术语，默认 3
--   term_min_code: 输入码至少几码才补全术语，默认 2（一码匹配面太宽）
--   predict_max: 每次最多插入几个续写联想词，默认 2

local memory = require("wubi_memory")
local predict = require("wubi_predict")

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
      -- 只记录中文等非 ASCII 上屏；联想词不算忘码
      if text:find("[\128-\255]") and cand:get_genuine().type ~= "predict" then
        memory.record(text, is_from_pinyin(cand))
      end
    end
  end
  predict.touch_active()
  if ctx:get_option("predict") then
    local text = ctx:get_commit_text()
    if text ~= "" then predict.on_commit(text) end
  end
end

function M.init(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  env.reverse = ReverseLookup(config:get_string(ns .. "/dictionary") or "wubi86_jidian")
  env.pinyin = ReverseLookup(config:get_string(ns .. "/pinyin_dictionary") or "pinyin_simp")
  env.prefix = config:get_string(ns .. "/lookup_prefix") or "`"
  env.short_hint = config:get_bool(ns .. "/short_hint") ~= false
  env.opts = predict.options(config, ns)
  env.opts.wubi, env.opts.pinyin, env.opts.prefix = env.reverse, env.pinyin, env.prefix
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
  local pending = predict.candidates(ctx, env.opts)  -- 在第一个候选之后插入
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
            local exact = has_code(codes, code, true)
            if forgot and not exact then
              cand:get_genuine().comment = "〔" .. shortest_codes(codes) .. " 忘" .. forgot .. "〕"
            elseif exact and env.short_hint then
              -- 打的是全码，但这个字有更短的简码：提示简码，下次少打几键
              local short = shortest_codes(codes)
              if #short:match("%S+") < #code then
                cand:get_genuine().comment = "〔简 " .. short .. "〕"
              end
            end
          end
        end
      end
      yield(cand)
      if pending then
        for _, p in ipairs(pending) do yield(p) end
        pending = nil
      end
    end
  end
  if pending then
    for _, p in ipairs(pending) do yield(p) end
  end
end

return M
