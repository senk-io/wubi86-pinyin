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
-- 5. 两码排序：整个输入正好两个字母时，依次为二级简码（两码打全的五笔候选）、
--    三级简码（再打一码就能上屏的五笔候选）、拼音、其余五笔候选。
--    三级简码和其余五笔两组，组内按用户词频排：选得多的在前。Rime 码表把用过的字放在前面，
--    但用过的字之间按编码顺序排，不按次数；候选的 quality 含用户词频，这里按它重新排。
--
-- 配置（schema 中与 filter 同名的节点）：
--   dictionary: 用于反查的五笔码表名
--   lookup_prefix: 学码模式前缀，默认 "`"
--   short_hint: 全码打出时是否提示简码，默认 true

-- 去噪、提示、忘码记录都是附加功能，任何一处出错都只跳过它自己，候选照常送出，见 wubi_safe.lua。

local safe = require("wubi_safe")
local memory = safe.require("wubi_memory")

local M = {}

-- 不是拼音的候选：五笔（码表、用户词、补全）和标点。标点不能算作拼音，
-- 否则会被当成简拼噪音丢掉（按 / . [ 时候选消失或只剩全角），上屏时还会被记成忘码
local NOT_PINYIN = { table = true, user_table = true, completion = true, punct = true }

local function is_from_pinyin(cand)
  return not NOT_PINYIN[cand:get_genuine().type]
end

local function on_commit(ctx)
  local segs = ctx.composition:toSegmentation():get_segments()
  for _, seg in ipairs(segs) do
    local cand = seg:get_selected_candidate()
    local status = seg.status
    if cand and (status == "kSelected" or status == "kConfirmed") then
      local text = cand.text
      -- 只记录中文等非 ASCII 上屏
      if text:find("[\128-\255]") then
        safe.call("memory", memory.record, text, is_from_pinyin(cand))
      end
    end
  end
end

local function setup(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  env.reverse = ReverseLookup(config:get_string(ns .. "/dictionary") or "wubi86_jidian")
  env.prefix = config:get_string(ns .. "/lookup_prefix") or "`"
  env.short_hint = config:get_bool(ns .. "/short_hint") ~= false
  return true
end

function M.init(env)
  -- 初始化失败（如码表缺失）时过滤器原样放行全部候选
  env.ready = safe.call("init", setup, env)
  env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
    if env.ready then safe.call("commit", on_commit, ctx) end
  end)
end

function M.fini(env)
  if env.commit_conn then env.commit_conn:disconnect() end
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

-- 编码提示：写在候选注释里
local function annotate(cand, code, env)
  local codes = env.reverse:lookup(cand.text)
  if codes == "" then return end
  if not has_code(codes, code, false) then
    cand:get_genuine().comment = "〔" .. shortest_codes(codes) .. "〕"
    return
  end
  local forgot = safe.call("memory", memory.count, cand.text)
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

-- 判断候选是不是噪音，并更新 state 中跨候选的状态；返回 true 表示丢掉
local function is_noise(cand, ctx, env, state)
  local input = ctx.input:sub(cand.start + 1, cand._end)
  local lookup_mode = input:sub(1, #env.prefix) == env.prefix
  local code = lookup_mode and input:sub(#env.prefix + 1) or input
  local from_pinyin = is_from_pinyin(cand)
  local rest = #ctx.input:sub(cand.start + 1)
  local full = from_pinyin and syllable_length(cand.preedit) >= rest

  local noise = false
  if from_pinyin and not lookup_mode then
    noise = is_abbreviated(cand.preedit)
      or (state.seen_wubi and not full)
      or (state.seen_full_phrase and cand.type == "sentence")
  end
  if not state.emoji_on and is_emoji(cand.text) then
    noise = true
  end

  state.seen_wubi = state.seen_wubi or not from_pinyin
  state.seen_full_phrase = state.seen_full_phrase or (full and cand.type ~= "sentence")

  if not noise and state.hint_on then
    safe.call("hint", annotate, cand, code, env)
  end
  return noise
end

-- 两码输入时候选的档次：1 二级简码，2 三级简码，3 拼音，4 其余五笔。
-- 五笔补全候选的注释是"~"加上还差的编码，差一码的就是三级简码
local function two_key_tier(cand)
  if is_from_pinyin(cand) then return 3 end
  local genuine = cand:get_genuine()
  if genuine.type ~= "completion" then return 1 end
  if (genuine.comment or ""):match("^~%l$") then return 2 end
  return 4
end

-- 组内按 quality 从高到低排，相同时保持原顺序（table.sort 不稳定，所以带上原位置）。
-- quality 先按 0.0001 取整：码表自带的字因词频不同只差百万分之一左右，不应改变它们原来的顺序；
-- 选过的字每多选一次约高 0.007。取整后再比较，比较关系仍可传递
local QUALITY_STEP = 1e-4

local function sort_by_quality(list)
  local keyed = {}
  for i, cand in ipairs(list) do
    keyed[i] = { cand = cand, level = math.floor(cand.quality / QUALITY_STEP), index = i }
  end
  table.sort(keyed, function(a, b)
    if a.level ~= b.level then return a.level > b.level end
    return a.index < b.index
  end)
  for i, item in ipairs(keyed) do list[i] = item.cand end
end

-- 候选的 yield 都在 pcall 之外：附加逻辑出错时 is_noise 返回 nil，候选照常送出
function M.func(translation, env)
  if not env.ready then
    for cand in translation:iter() do yield(cand) end
    return
  end
  local ctx = env.engine.context
  local state = {
    hint_on = ctx:get_option("code_hint"),
    emoji_on = ctx:get_option("emoji"),
    seen_wubi = false,
    seen_full_phrase = false,
  }
  -- 两码时要等全部候选都过一遍才知道各档有哪些（最多几百个），二级简码以外的先存起来
  local tiers = ctx.input:match("^%l%l$") and { {}, {}, {} }
  for cand in translation:iter() do
    -- 档次要在 is_noise 之前取：编码提示会改写补全候选的注释
    local tier = tiers and safe.call("order", two_key_tier, cand)
    if not safe.call("filter", is_noise, cand, ctx, env, state) then
      if not tiers or tier == 1 then
        yield(cand)
      else
        local list = tiers[(tier or 3) - 1]
        list[#list + 1] = cand
      end
    end
  end
  if tiers then
    -- 排序出错时保持原顺序（sort_by_quality 只在全部成功后才写回）
    safe.call("order", sort_by_quality, tiers[1])
    safe.call("order", sort_by_quality, tiers[3])
    for _, list in ipairs(tiers) do
      for _, cand in ipairs(list) do yield(cand) end
    end
  end
end

return M
