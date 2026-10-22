#!/usr/bin/env sh
# 把 schema/ 与 data/ 中某个安装包需要的文件汇总成 Rime 用户目录所需的平铺结构。
# 用法：scripts/assemble.sh <目标目录> [wubi86-pinyin|pinyin]
#   不给出安装包时，读取仓库根目录的 VARIANT 文件（发布的 zip 里有），没有则为 wubi86-pinyin。
#   wubi86-pinyin：SENK五笔混拼输入法86版（方案 wubi86_pinyin）
#   pinyin：SENK拼音输入法（方案 senk_pinyin）
# 生成的 default.custom.yaml 列出目标目录里已有的本项目方案，顺序固定：五笔在前，拼音在后。
# 第一个是新会话的默认方案；SENK 程序按菜单栏里选的「SENK五笔」「SENK拼音」切换方案。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?usage: assemble.sh <dest> [wubi86-pinyin|pinyin]}
variant=${2:-$(cat "$root/VARIANT" 2>/dev/null || echo wubi86-pinyin)}
case "$variant" in
  wubi86-pinyin) schema=wubi86_pinyin ;;
  pinyin) schema=senk_pinyin ;;
  *) echo "未知的安装包：$variant" >&2; exit 1 ;;
esac

mkdir -p "$dest/lua"
# 旧版本的本地模型接入已移除，删掉留下的脚本
rm -f "$dest/lua/wubi_predict.lua" "$dest/lua/wubi_predict_switch.lua" "$dest/lua/pinyin_filter.lua"
# 两个包共用：拼音词库
cp "$root"/data/pinyin_simp.*.yaml "$dest/"
cp "$root/schema/$schema.schema.yaml" "$root/schema/senk_punctuation.yaml" "$dest/"
cp "$root/schema/lua/senk_uppercase.lua" "$dest/lua/"
if [ "$variant" = wubi86-pinyin ]; then
  cp "$root"/data/wubi86_jidian*.yaml "$dest/"
  for f in wubi_safe wubi_mixed_filter wubi_memory wubi_topup; do cp "$root/schema/lua/$f.lua" "$dest/lua/"; done
fi

{
  echo "# 由 wubi86-pinyin 的安装脚本生成。已有其它方案的用户可以自行合并 schema_list"
  echo "patch:"
  echo "  schema_list:"
  for s in wubi86_pinyin senk_pinyin; do
    [ ! -f "$dest/$s.schema.yaml" ] || echo "    - schema: $s"
  done
  echo "  menu/page_size: 6"
} > "$dest/default.custom.yaml"
