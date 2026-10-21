#!/usr/bin/env sh
# 可选：安装拼音整句语言模型，一口气打一长串拼音时整句首选更准（基准 29/36 → 35/36，见 tests/bench.sh）。
# 模型 zh-hans-t-essay-bgw.gram 来自 lotem/rime-octagram-data，LGPL-3.0，不随本仓库分发：
# 由本脚本从固定版本下载并校验 SHA-256。鼠须管自带加载它的 librime-octagram 插件。
#
# 用法：sh scripts/install-grammar-macos.sh            安装（可重复运行）
#       sh scripts/install-grammar-macos.sh --remove   卸载
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rime_dir="$HOME/Library/Rime"
gram="zh-hans-t-essay-bgw.gram"
commit="f8ce3b534733e489a8470a7c2adf5a154e8ea069"
sha256="d3cb2438c1fdcd6a855dd6ca8f5c1060a29273c6b64c2c2c69af67cd71b6aa7e"
url="https://raw.githubusercontent.com/lotem/rime-octagram-data/${commit}/${gram}"
custom="$rime_dir/wubi86_pinyin.custom.yaml"
marker="# wubi86-pinyin: grammar"
squirrel_app="/Library/Input Methods/Squirrel.app"
squirrel="$squirrel_app/Contents/MacOS/Squirrel"

# 重新部署；鼠须管进程没运行时 --reload 不起作用，先在后台启动
reload() {
  [ -x "$squirrel" ] || return 0
  if ! pgrep -x Squirrel >/dev/null 2>&1; then
    open -g "$squirrel_app"
    i=0
    while [ "$i" -lt 15 ] && ! pgrep -x Squirrel >/dev/null 2>&1; do
      sleep 1
      i=$((i + 1))
    done
  fi
  "$squirrel" --reload
}

# wubi86_pinyin.custom.yaml 只在是本脚本写的时候才改动或删除
ours() {
  [ ! -f "$custom" ] || head -n 1 "$custom" | grep -qx "$marker"
}

if [ "${1:-}" = "--remove" ]; then
  # 先撤配置再删模型，方案任何时候都不会引用不存在的文件
  if [ -f "$custom" ] && ours; then rm -f "$custom"; fi
  rm -f "$rime_dir/$gram"
  reload
  echo "拼音语言模型已卸载。"
  exit 0
fi

if ! ours; then
  echo "${custom} 已存在且不是本脚本生成的。为免覆盖你的设置，已停止。" >&2
  echo "请把 ${root}/schema/optional/grammar.custom.yaml 里 patch 下的内容合并进去，再把 ${gram} 放进 ${rime_dir}。" >&2
  exit 1
fi

mkdir -p "$rime_dir"
if [ -f "$rime_dir/$gram" ] && [ "$(shasum -a 256 "$rime_dir/$gram" | awk '{print $1}')" = "$sha256" ]; then
  echo "语言模型已是最新，跳过下载。"
else
  echo "正在下载拼音语言模型（约 39MB）..."
  curl -fL --progress-bar -o "$rime_dir/$gram.download" "$url"
  if [ "$(shasum -a 256 "$rime_dir/$gram.download" | awk '{print $1}')" != "$sha256" ]; then
    rm -f "$rime_dir/$gram.download"
    echo "语言模型校验失败，已停止。" >&2
    exit 1
  fi
  mv "$rime_dir/$gram.download" "$rime_dir/$gram"
fi
# 模型就位后再写配置
cp "$root/schema/optional/grammar.custom.yaml" "$custom"
reload
echo "拼音语言模型已安装并重新部署。卸载：sh scripts/install-grammar-macos.sh --remove"
