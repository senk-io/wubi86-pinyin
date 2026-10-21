#!/usr/bin/env sh
# 可选：安装拼音整句语言模型，一口气打一长串拼音时整句首选更准（基准 29/36 → 35/36，见 tests/bench.sh）。
# 模型 zh-hans-t-essay-bgw.gram 来自 lotem/rime-octagram-data，LGPL-3.0，不随本仓库分发：
# 由本脚本从固定版本下载并校验 SHA-256。鼠须管自带加载它的 librime-octagram 插件。
# 两个安装包的方案（SENK五笔混拼输入法86版、SENK拼音输入法）都适用；装了哪个就配置哪个，之后再装另一个包时重新运行即可。
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

# 已安装的方案（两个安装包各一个），各自写一份 <方案>.custom.yaml
schemas=""
for s in wubi86_pinyin senk_pinyin; do
  [ ! -f "$rime_dir/$s.schema.yaml" ] || schemas="$schemas $s"
done

# <方案>.custom.yaml 只在是本脚本写的时候才改动或删除
ours() {
  [ ! -f "$1" ] || head -n 1 "$1" | grep -qx "$marker"
}

if [ "${1:-}" = "--remove" ]; then
  # 先撤配置再删模型，方案任何时候都不会引用不存在的文件
  for s in wubi86_pinyin senk_pinyin; do
    custom="$rime_dir/$s.custom.yaml"
    if [ -f "$custom" ] && ours "$custom"; then rm -f "$custom"; fi
  done
  rm -f "$rime_dir/$gram"
  reload
  echo "拼音语言模型已卸载。"
  exit 0
fi

if [ -z "$schemas" ]; then
  echo "${rime_dir} 里没有找到本项目的方案，请先运行 install-macos.sh。" >&2
  exit 1
fi
for s in $schemas; do
  if ! ours "$rime_dir/$s.custom.yaml"; then
    echo "${rime_dir}/$s.custom.yaml 已存在且不是本脚本生成的。为免覆盖你的设置，已停止。" >&2
    echo "请把 ${root}/schema/optional/$s.custom.yaml 里 patch 下的内容合并进去，再重新运行。" >&2
    exit 1
  fi
done

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
for s in $schemas; do
  cp "$root/schema/optional/$s.custom.yaml" "$rime_dir/$s.custom.yaml"
done
reload
echo "拼音语言模型已安装并重新部署。卸载：sh scripts/install-grammar-macos.sh --remove"
