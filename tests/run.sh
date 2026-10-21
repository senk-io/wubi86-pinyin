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
  # 模拟已安装 wubi86d：联想相关用例通过 "$ " 行直接读写这些文件
  mkdir -p "$user/wubi86d"
  printf '笔记\n工作\n' > "$user/wubi86d/folders.txt"
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
exit $status
