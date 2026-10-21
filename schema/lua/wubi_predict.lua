-- 项目术语与本地模型联想（输入法一侧）
--
-- 与常驻进程 wubi86d 通过 <Rime 用户目录>/wubi86d/ 下的文件交换数据（格式见 helper/daemon.go）。
-- 这里只做读写小文件这类毫秒级操作，从不等待模型。没装 wubi86d（不存在 folders.txt）时什么都不做。
--
-- 1. 项目术语：wubi86d 从当前资料文件夹抽出项目名、系统名、内部叫法等，写成 terms/<名称>.txt。
--    输入码是某个术语的五笔词码、全拼或拼音首字母的前缀时，把术语插到候选第 2 位起。
-- 2. 续写联想（默认关闭）：上屏后写 context.txt，wubi86d 生成联想后写 suggest.txt，匹配方式同上。
--
-- 首选始终不动，保留五笔简码按空格上屏的习惯。

local M = {}

local CONTEXT_RUNES = 48

local dir = nil
local enabled = false    -- wubi86d 是否已安装
local seq = nil          -- 最近一次写出的上文序号
local counter = 0
local recent = ""
local cached = { seq = nil, profile = "", phrases = {} }
local codes_cache = {}

local function base_dir()
  if not dir then
    dir = rime_api.get_user_data_dir() .. "/wubi86d"
  end
  return dir
end

local function read_lines(name)
  local f = io.open(base_dir() .. "/" .. name, "r")
  if not f then return nil end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

-- 原子写：先写临时文件再改名。Windows 上目标存在时 rename 会失败，先删除再改名。
local function write_file(name, content)
  local path = base_dir() .. "/" .. name
  local tmp = path .. ".lua.tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(content)
  f:close()
  if not os.rename(tmp, path) then
    os.remove(path)
    return os.rename(tmp, path) ~= nil
  end
  return true
end

-- 没装时每 30 秒重新检查一次，装好 wubi86d 后不用重启输入法
local checked_at = 0
function M.available()
  if not enabled and os.time() - checked_at >= 30 then
    checked_at = os.time()
    enabled = read_lines("folders.txt") ~= nil
  end
  return enabled
end

local function tail_runes(s, n)
  local len = utf8.len(s) or 0
  if len <= n then return s end
  return s:sub(utf8.offset(s, len - n + 1))
end

-- 上屏后调用：更新上文并通知 wubi86d
function M.on_commit(text)
  if not M.available() then return end
  text = text:gsub("[\r\n]", " ")
  recent = tail_runes(recent .. text, CONTEXT_RUNES)
  counter = counter + 1
  seq = string.format("%d%04d", os.time(), counter % 10000)
  write_file("context.txt", seq .. "\n" .. text .. "\n" .. recent .. "\n")
end

-- 当前上文对应的联想词；wubi86d 还没算好（序号对不上）时返回空表
function M.suggestions()
  if not seq then return cached.profile, {} end
  if cached.seq ~= seq then
    local lines = read_lines("suggest.txt")
    if not lines or lines[1] ~= seq then return "", {} end
    cached = { seq = seq, profile = lines[2] or "", phrases = {} }
    for i = 3, #lines do
      if lines[i] ~= "" then cached.phrases[#cached.phrases + 1] = lines[i] end
    end
  end
  return cached.profile, cached.phrases
end

-- 当前资料文件夹名：每秒最多读一次 profile.txt
local profile_name, profile_at = "", -1
local function current_profile()
  local now = os.time()
  if now ~= profile_at then
    profile_at = now
    profile_name = ((read_lines("profile.txt") or {})[1] or "")
  end
  return profile_name
end

-- 与 helper/daemon.go 的 safeName 一致
local function safe_name(name)
  return (name:gsub('[/\\:*?"<>|%c]', "_"))
end

-- 当前资料文件夹的术语表：{ {text=, weight=}, ... }，按出现次数降序。
-- 每秒最多检查一次版本行，有变化才重新加载。
local terms = { profile = nil, version = nil, list = {}, checked = -1 }
function M.terms()
  local profile = current_profile()
  if profile == "" then return "", {} end
  local now = os.time()
  if terms.profile == profile and terms.checked == now then
    return profile, terms.list
  end
  terms.checked = now
  local f = io.open(base_dir() .. "/terms/" .. safe_name(profile) .. ".txt", "r")
  if not f then
    terms.profile, terms.version, terms.list = profile, nil, {}
    return profile, terms.list
  end
  local version = f:read("l")
  if terms.profile ~= profile or terms.version ~= version then
    local list = {}
    for line in f:lines() do
      local text, weight = line:match("^(.-)\t(%d+)$")
      if text and text ~= "" then list[#list + 1] = { text = text, weight = tonumber(weight) } end
    end
    terms.profile, terms.version, terms.list = profile, version, list
  end
  f:close()
  return profile, terms.list
end

-- 一个联想词能被哪些输入码前缀匹配：五笔词码、全拼、拼音首字母
-- wubi / pinyin 是 ReverseLookup 对象
local function first_code(codes, longest)
  local best
  for code in codes:gmatch("%S+") do
    if not best or (longest and #code > #best) or (not longest and #code < #best) then
      best = code
    end
  end
  return best
end

-- 按五笔 86 的词组编码规则由单字全码算出词码
local function wubi_word_code(full)
  local n = #full
  if n == 1 then return full[1] end
  if n == 2 then return full[1]:sub(1, 2) .. full[2]:sub(1, 2) end
  if n == 3 then return full[1]:sub(1, 1) .. full[2]:sub(1, 1) .. full[3]:sub(1, 2) end
  return full[1]:sub(1, 1) .. full[2]:sub(1, 1) .. full[3]:sub(1, 1) .. full[n]:sub(1, 1)
end

function M.codes(phrase, wubi, pinyin)
  local hit = codes_cache[phrase]
  if hit then return hit end
  local result = {}
  local word = wubi:lookup(phrase)
  if word ~= "" then
    result[#result + 1] = first_code(word, true)
  else
    local full = {}
    for _, cp in utf8.codes(phrase) do
      local c = first_code(wubi:lookup(utf8.char(cp)), true)
      if not c then full = nil break end
      full[#full + 1] = c
    end
    if full then result[#result + 1] = wubi_word_code(full) end
  end
  -- 拼音：汉字取第一个读音；连续的英文字母和数字原样作为一节（如 SenkNet-API → senknet api）
  local spelled, initials, ascii = {}, {}, ""
  local function flush_ascii()
    if ascii ~= "" then
      spelled[#spelled + 1] = ascii:lower()
      initials[#initials + 1] = ascii:sub(1, 1):lower()
      ascii = ""
    end
  end
  for _, cp in utf8.codes(phrase) do
    local ch = utf8.char(cp)
    if ch:match("^%w$") then
      ascii = ascii .. ch
    else
      flush_ascii()
      local py = pinyin:lookup(ch):match("%S+")
      if py then
        spelled[#spelled + 1] = py
        initials[#initials + 1] = py:sub(1, 1)
      elseif cp >= 0x80 then
        spelled = nil
        break
      end
    end
  end
  if spelled then
    flush_ascii()
    result[#result + 1] = table.concat(spelled)
    result[#result + 1] = table.concat(initials)
  end
  codes_cache[phrase] = result
  return result
end

function M.matches(phrase, input, wubi, pinyin)
  for _, code in ipairs(M.codes(phrase, wubi, pinyin)) do
    if code:sub(1, #input) == input then return true end
  end
  return false
end

-- 轮换资料文件夹：读 folders.txt，在「不用文件夹」和各文件夹之间循环，写 profile.txt
function M.next_profile()
  local folders = read_lines("folders.txt") or {}
  local current = (read_lines("profile.txt") or {})[1] or ""
  local ring = { "" }
  for _, name in ipairs(folders) do
    if name ~= "" then ring[#ring + 1] = name end
  end
  local next_name = ring[1]
  for i, name in ipairs(ring) do
    if name == current then
      next_name = ring[i % #ring + 1]
      break
    end
  end
  write_file("profile.txt", next_name .. "\n")
  profile_name, profile_at = next_name, os.time()
  -- 换了资料，用同样的上文请 wubi86d 重算一次；刚上屏一栏留空，不会重复记入历史
  if seq then
    counter = counter + 1
    seq = string.format("%d%04d", os.time(), counter % 10000)
    write_file("context.txt", seq .. "\n\n" .. recent .. "\n")
  end
  return next_name
end

return M
