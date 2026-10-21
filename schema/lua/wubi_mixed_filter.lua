-- 五笔/拼音混输过滤器
--
-- 混输时同一段编码会同时出五笔候选和拼音候选，这里做两件事：
-- 1. 去噪（反引号学码模式下不过滤）：
--    - 拼音候选用到了简拼（只有声母的音节，如 adnt -> a d n t），多半是五笔码
--      被误当成拼音，丢掉；
--    - 输入码已经有五笔候选时，只匹配了输入前半段的拼音候选（adnt -> a -> 啊）
--      也是噪音，丢掉。
-- 2. 编码提示：不是用五笔打出来的候选，在注释里标出最短的五笔编码。
--    判断依据：候选文字的五笔编码中，没有一个以当前输入码开头。
--
-- 配置（schema 中与 filter 同名的节点）：
--   dictionary: 用于反查的五笔码表名
--   lookup_prefix: 学码模式前缀，默认 "`"
-- 开关：code_hint（关闭时不加注释）

local M = {}

local TABLE_TYPES = { table = true, user_table = true, completion = true }

function M.init(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  env.reverse = ReverseLookup(config:get_string(ns .. "/dictionary") or "wubi86_jidian")
  env.prefix = config:get_string(ns .. "/lookup_prefix") or "`"
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

local function has_prefix_code(codes, input)
  for code in codes:gmatch("%S+") do
    if code:sub(1, #input) == input then
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

function M.func(translation, env)
  local ctx = env.engine.context
  local hint_on = ctx:get_option("code_hint")
  local seen_wubi = false
  for cand in translation:iter() do
    local input = ctx.input:sub(cand.start + 1, cand._end)
    local lookup_mode = input:sub(1, #env.prefix) == env.prefix
    local from_pinyin = not TABLE_TYPES[cand.type]
    seen_wubi = seen_wubi or not from_pinyin
    local noise = from_pinyin and not lookup_mode
      and (is_abbreviated(cand.preedit)
        or (seen_wubi and syllable_length(cand.preedit) < #ctx.input:sub(cand.start + 1)))
    if not noise then
      if hint_on then
        local code = lookup_mode and input:sub(#env.prefix + 1) or input
        local codes = env.reverse:lookup(cand.text)
        if codes ~= "" and not has_prefix_code(codes, code) then
          cand:get_genuine().comment = "〔" .. shortest_codes(codes) .. "〕"
        end
      end
      yield(cand)
    end
  end
end

return M
