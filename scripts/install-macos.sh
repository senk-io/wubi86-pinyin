#!/usr/bin/env sh
# 安装到鼠须管（Squirrel）用户目录并重新部署。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rime_dir="$HOME/Library/Rime"
mkdir -p "$rime_dir"

# 不覆盖用户已有的 default.custom.yaml，避免丢掉其它方案
if [ -f "$rime_dir/default.custom.yaml" ]; then
  keep="$rime_dir/default.custom.yaml.keep"
  cp "$rime_dir/default.custom.yaml" "$keep"
fi
"$root/scripts/assemble.sh" "$rime_dir"
if [ -n "${keep:-}" ]; then
  mv "$keep" "$rime_dir/default.custom.yaml"
  echo "保留了你原有的 default.custom.yaml，请在 schema_list 中加入：- schema: wubi86_pinyin"
fi

squirrel="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
if [ -x "$squirrel" ]; then
  "$squirrel" --reload
  echo "已安装并重新部署。"
else
  echo "未找到鼠须管，请先安装：https://rime.im/download/ ，然后在菜单中选择「重新部署」。"
fi
