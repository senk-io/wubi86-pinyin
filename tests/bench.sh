#!/usr/bin/env sh
# 拼音长句基准：逐句输入 pinyin_bench.txt，统计首选完全正确的句数，列出错句。
# 用法：tests/bench.sh [语言模型.gram] [最少正确句数]
#   给出 .gram 时按 schema/optional/grammar.custom.yaml 启用语言模型（需要 librime-octagram）。
#   给出最少正确句数时，低于它就以失败退出（供 CI 防止退化）。
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shared=${RIME_SHARED_DATA:-/usr/share/rime-data}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gcc -O2 -o "$work/rime_probe" "$here/rime_probe.c" -lrime
"$root/scripts/assemble.sh" "$work/user" >/dev/null
if [ -n "${1:-}" ]; then
  cp "$1" "$work/user/"
  cp "$root/schema/optional/grammar.custom.yaml" "$work/user/wubi86_pinyin.custom.yaml"
fi
export RIME_USER="$work/user"

grep -v '^#' "$here/pinyin_bench.txt" | cut -f1 | sed 's/^/!1 /' \
  | "$work/rime_probe" "$shared" "$work/user" wubi86_pinyin 1 2>/dev/null \
  | sed -n 's/^commit [a-z]* -> //p' > "$work/actual.txt"
grep -v '^#' "$here/pinyin_bench.txt" | cut -f2 > "$work/expected.txt"

total=$(wc -l < "$work/expected.txt" | tr -d ' ')
pass=$(paste "$work/expected.txt" "$work/actual.txt" | awk -F '\t' '$1 == $2' | wc -l | tr -d ' ')
paste "$work/expected.txt" "$work/actual.txt" | awk -F '\t' '$1 != $2 {print "  期望 " $1 "，得到 " $2}'
echo "正确 ${pass}/${total}"
# 在 GitHub Actions 里同时输出为注释，方便不下载日志就看到结果
[ -z "${GITHUB_ACTIONS:-}" ] || echo "::notice title=pinyin-bench ${1:+grammar}::正确 ${pass}/${total}"
[ -z "${2:-}" ] || [ "$pass" -ge "$2" ]
