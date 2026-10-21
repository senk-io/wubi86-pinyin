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
"$root/scripts/assemble.sh" "$work/user"
# 模拟已安装 wubi86d：联想相关用例通过 "$ " 行直接读写这些文件
mkdir -p "$work/user/wubi86d"
printf '笔记\n工作\n' > "$work/user/wubi86d/folders.txt"
export RIME_USER="$work/user"
grep -v '^#' "$here/cases.txt" \
  | "$work/rime_probe" "$shared" "$work/user" wubi86_pinyin 6 2>/dev/null > "$work/actual.txt"

if [ "${1:-}" = "--update" ]; then
  cp "$work/actual.txt" "$here/expected.txt"
  echo "expected.txt updated"
else
  diff -u "$here/expected.txt" "$work/actual.txt" && echo "all cases passed"
fi
