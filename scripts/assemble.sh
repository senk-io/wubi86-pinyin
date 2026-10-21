#!/usr/bin/env sh
# 把 schema/ 与 data/ 汇总成 Rime 用户目录所需的平铺结构。
# 用法：scripts/assemble.sh <目标目录>
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?usage: assemble.sh <dest>}
mkdir -p "$dest/lua"
cp "$root"/schema/*.yaml "$dest/"
cp "$root"/schema/lua/*.lua "$dest/lua/"
cp "$root"/data/*.yaml "$dest/"
