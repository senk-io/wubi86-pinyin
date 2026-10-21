#!/usr/bin/env sh
# 把 schema/ 与 data/ 中某个安装包需要的文件汇总成 Rime 用户目录所需的平铺结构。
# 用法：scripts/assemble.sh <目标目录> [wubi86-pinyin|pinyin]
#   不给出安装包时，读取仓库根目录的 VARIANT 文件（发布的 zip 里有），没有则为 wubi86-pinyin。
#   wubi86-pinyin：五笔86·拼音混输（方案 wubi86_pinyin）
#   pinyin：纯拼音（方案 senk_pinyin）
# 生成的 default.custom.yaml 把本包的方案放在第一位；目标目录里已有另一个包的方案时一并列出。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?usage: assemble.sh <dest> [wubi86-pinyin|pinyin]}
variant=${2:-$(cat "$root/VARIANT" 2>/dev/null || echo wubi86-pinyin)}
case "$variant" in
  wubi86-pinyin) schema=wubi86_pinyin other=senk_pinyin ;;
  pinyin) schema=senk_pinyin other=wubi86_pinyin ;;
  *) echo "未知的安装包：$variant" >&2; exit 1 ;;
esac

mkdir -p "$dest/lua"
# 两个包共用：拼音词库、术语补全
cp "$root"/data/pinyin_simp.*.yaml "$dest/"
cp "$root"/schema/lua/wubi_predict.lua "$root"/schema/lua/wubi_predict_switch.lua "$dest/lua/"
cp "$root/schema/$schema.schema.yaml" "$dest/"
if [ "$variant" = wubi86-pinyin ]; then
  cp "$root"/data/wubi86_jidian*.yaml "$dest/"
  for f in wubi_mixed_filter wubi_memory wubi_topup; do cp "$root/schema/lua/$f.lua" "$dest/lua/"; done
else
  cp "$root/schema/lua/pinyin_filter.lua" "$dest/lua/"
fi

{
  echo "# 由 wubi86-pinyin 的安装脚本生成。已有其它方案的用户可以自行合并 schema_list"
  echo "patch:"
  echo "  schema_list:"
  echo "    - schema: $schema"
  [ ! -f "$dest/$other.schema.yaml" ] || echo "    - schema: $other"
  echo "  menu/page_size: 6"
} > "$dest/default.custom.yaml"
