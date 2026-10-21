-- 纯拼音方案的过滤器
--
-- 1. 项目术语（开关 terms，默认开）：当前资料文件夹的术语里，全拼或拼音首字母以当前输入码
--    开头的，插在第 2 位起，见 wubi_predict.lua。
-- 2. 续写联想（开关 predict，默认关）：上屏时把上文交给 wubi_predict；打下一个词时，
--    匹配当前输入码的联想词同样插在第 2 位起。
--
-- 配置（schema 中与 filter 同名的节点）：
--   pinyin_dictionary: 用于给术语注音的拼音词库
--   term_max / term_min_code / predict_max: 同 wubi_mixed_filter

local predict = require("wubi_predict")

local M = {}

function M.init(env)
  local config = env.engine.schema.config
  local ns = env.name_space
  env.opts = predict.options(config, ns)
  env.opts.pinyin = ReverseLookup(config:get_string(ns .. "/pinyin_dictionary") or "pinyin_simp")
  env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
    predict.touch_active()
    if ctx:get_option("predict") then
      local text = ctx:get_commit_text()
      if text ~= "" then predict.on_commit(text) end
    end
  end)
end

function M.fini(env)
  env.commit_conn:disconnect()
end

function M.func(translation, env)
  local pending, exact = predict.candidates(env.engine.context, env.opts)  -- 在第一个候选之后插入
  for cand in translation:iter() do
    local promote = pending and exact and cand.type == "sentence"
    if promote then
      yield(exact)  -- 首选是凑出来的整句，全拼完全一致的术语排到它前面
    end
    yield(cand)
    if pending then
      for _, p in ipairs(pending) do
        if not (promote and p == exact) then yield(p) end
      end
      pending = nil
    end
  end
  if pending then
    for _, p in ipairs(pending) do yield(p) end
  end
end

return M
