-- 五笔顶字：打满四码后再按字母键，先把五笔首选上屏，新按的键作为下一个字的编码。
-- 混输时不能直接用 speller/max_code_length：它不管后面是不是在打拼音，
-- 会把 shuj（相间）这样的拼音前四码当五笔顶上屏，把 shujuku 打散。
-- 这里只在「加上新按的键后，整串已经不可能是拼音」时才顶字，打拼音时不受影响。
--
-- 配置：wubi_topup/code_length，默认 4

local kNoop = 2

-- data/pinyin_simp.dict.yaml 中出现的全部音节
local SYLLABLES = [[
  a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang
  cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan
  chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di
  dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng
  fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
  ha hai han hang hao he hei hen heng hm hong hou hu hua huai huan huang hui hun huo ji jia jian
  jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou
  ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie
  lin ling liu lo long lou lu luan lue lun luo lv m ma mai man mang mao me mei men meng mi mian
  miao mie min ming miu mo mou mu n na nai nan nang nao ne nei nen neng ng ni nian niang niao nie
  nin ning niu nong nou nu nuan nue nuo nv o ou pa pai pan pang pao pei pen peng pi pian piao pie
  pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao
  re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang
  shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su
  suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun
  tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan
  xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei
  zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan
  zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
]]

local syllables, prefixes = {}, {}
for s in SYLLABLES:gmatch("%a+") do
  syllables[s] = true
  for i = 1, #s do prefixes[s:sub(1, i)] = true end
end

-- 能否切成若干完整音节，最后一段允许是还没打完的音节
local function pinyin_viable(code)
  local n = #code
  local reach = { [0] = true }
  for i = 0, n - 1 do
    if reach[i] then
      for j = i + 1, math.min(n, i + 6) do
        local part = code:sub(i + 1, j)
        if j == n and prefixes[part] then return true end
        if syllables[part] then reach[j] = true end
      end
    end
  end
  return reach[n] == true
end

local safe = require("wubi_safe")

local M = {}

function M.init(env)
  env.code_length = safe.call("topup init", function()
    return env.engine.schema.config:get_int("wubi_topup/code_length")
  end) or 4
end

local function topup(key, env)
  if key:release() or key:ctrl() or key:alt() or key:super() then return end
  local code = key.keycode
  if code < 0x61 or code > 0x7a then return end
  local ctx = env.engine.context
  local input = ctx.input
  if #input ~= env.code_length or input:find("[^a-z]") or ctx:get_option("ascii_mode") then
    return
  end
  local cand = ctx:get_selected_candidate()
  if not cand or cand.start ~= 0 or cand._end ~= #input then return end
  local kind = cand:get_genuine().type
  if kind ~= "table" and kind ~= "user_table" then return end
  if pinyin_viable(input .. string.char(code)) then return end
  ctx:commit()
end

-- 顶字出错时什么都不做，按键照常交给后面的组件
function M.func(key, env)
  safe.call("topup", topup, key, env)
  return kNoop
end

M.pinyin_viable = pinyin_viable
return M
