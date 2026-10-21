#!/usr/bin/env sh
# 端到端测试：用 librime 部署方案，逐条输入 cases.txt，与 expected.txt 比对。
# 依赖：librime 开发包、librime-lua 插件、gcc。
# 用法：tests/run.sh          比对
#       tests/run.sh --update 重新生成 expected.txt
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shared=${RIME_SHARED_DATA:-/usr/share/rime-data}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gcc -O2 -o "$work/rime_probe" "$here/rime_probe.c" -lrime
status=0
# 每个安装包一组用例：<安装包> <方案> <用例文件> <期望结果文件>
while read -r variant schema cases expected; do
  user="$work/$variant"
  "$root/scripts/assemble.sh" "$user" "$variant"
  export RIME_USER="$user"
  grep -v '^#' "$here/$cases" \
    | "$work/rime_probe" "$shared" "$user" "$schema" 6 2>/dev/null > "$work/actual.txt"
  if [ "${1:-}" = "--update" ]; then
    cp "$work/actual.txt" "$here/$expected"
    echo "$expected updated"
  elif diff -u "$here/$expected" "$work/actual.txt"; then
    echo "$variant: all cases passed"
  else
    status=1
  fi
done <<LIST
wubi86-pinyin wubi86_pinyin cases.txt expected.txt
pinyin senk_pinyin pinyin_cases.txt pinyin_expected.txt
LIST

# 附加功能出错时基本输入不受影响：把忘码记录模块换成加载即报错或每次调用都报错的版本，
# 基本用例的结果必须和正常时完全一样（见 schema/lua/wubi_safe.lua）。
[ "${1:-}" = "--update" ] && exit $status
while read -r variant schema cases; do
  healthy="$work/$variant-healthy"
  "$root/scripts/assemble.sh" "$healthy" "$variant"
  grep -v '^#' "$here/$cases" \
    | RIME_USER="$healthy" "$work/rime_probe" "$shared" "$healthy" "$schema" 6 2>/dev/null > "$work/healthy.txt"
  for mode in load call; do
    broken="$work/$variant-$mode"
    "$root/scripts/assemble.sh" "$broken" "$variant"
    if [ "$mode" = load ]; then
      echo 'error("injected load failure")' > "$broken/lua/wubi_memory.lua"
    else
      echo 'return setmetatable({}, { __index = function() return function() error("injected call failure") end end })' > "$broken/lua/wubi_memory.lua"
    fi
    grep -v '^#' "$here/$cases" \
      | RIME_USER="$broken" "$work/rime_probe" "$shared" "$broken" "$schema" 6 2>/dev/null > "$work/broken.txt"
    if diff -u "$work/healthy.txt" "$work/broken.txt"; then
      echo "$variant: basic input survives add-on $mode failure"
    else
      status=1
    fi
  done
done <<LIST
wubi86-pinyin wubi86_pinyin fault_cases.txt
LIST
exit $status
