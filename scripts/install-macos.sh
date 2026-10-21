#!/usr/bin/env sh
# 安装鼠须管（Squirrel）与本方案，并重新部署。
# 已经装过鼠须管的，先卸载再从官方 Release 重新安装，保证用的是校验过签名的版本；
# ~/Library/Rime 中的用户数据（词频等）保留。
#
# 用法：sh scripts/install-macos.sh
# 环境变量：
#   SQUIRREL_VERSION  指定鼠须管版本（如 1.1.2），默认取 GitHub 上的最新正式版
#   SQUIRREL_TEAM_ID  期望的签名团队 ID，默认 28HU5A7B46（上游维护者的 Developer ID）
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
echo "wubi86-pinyin 安装脚本（版本 $Format:%h$）"
rime_dir="$HOME/Library/Rime"
squirrel_app="/Library/Input Methods/Squirrel.app"
squirrel="$squirrel_app/Contents/MacOS/Squirrel"
releases="https://github.com/rime/squirrel/releases"

install_squirrel() {
  major=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$major" -lt 13 ]; then
    echo "鼠须管需要 macOS 13 或更高版本，当前是 $(sw_vers -productVersion)。" >&2
    exit 1
  fi

  version=${SQUIRREL_VERSION:-}
  if [ -z "$version" ]; then
    # releases/latest 会跳转到 .../tag/<版本号>
    version=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$releases/latest" | sed 's#.*/tag/##')
  fi
  case "$version" in
    [0-9]*.[0-9]*) ;;
    *) echo "无法确定鼠须管版本（得到：${version}），可用 SQUIRREL_VERSION=1.1.2 指定。" >&2; exit 1 ;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  pkg="$tmp/Squirrel-$version.pkg"
  echo "正在下载鼠须管 $version ..."
  curl -fL --progress-bar -o "$pkg" "$releases/download/$version/Squirrel-$version.pkg"

  # 安装前校验包内应用的签名。不能装完再验：安装包的 postinstall 会在
  # Squirrel.app 内部生成预编译数据，之后整包签名校验必然失败。
  # 上游发布用的签名：Developer ID Application: Yuncao Liu (28HU5A7B46)
  pkgutil --expand-full "$pkg" "$tmp/expanded" >/dev/null
  app=$(find "$tmp/expanded" -type d -name Squirrel.app -prune | head -n 1)
  if [ -z "$app" ]; then
    echo "安装包里没有找到 Squirrel.app，已停止。" >&2
    exit 1
  fi
  if ! codesign --verify --deep --strict "$app"; then
    echo "鼠须管签名校验失败（见上方 codesign 输出），已停止。" >&2
    exit 1
  fi
  # 签名信息里的 Authority 行需要 -vv 才会输出
  team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$team" != "${SQUIRREL_TEAM_ID:-28HU5A7B46}" ]; then
    echo "鼠须管签名者不符：期望 ${SQUIRREL_TEAM_ID:-28HU5A7B46}，实际 ${team:-无}，已停止。" >&2
    exit 1
  fi
  echo "签名校验通过（TeamIdentifier=${team}）。"

  # 新安装包下载并校验通过后才卸载旧版，避免中途失败导致没有输入法可用
  if [ -e "$squirrel_app" ]; then
    echo "检测到已安装的鼠须管，先卸载再重新安装（保留 ~/Library/Rime 中的用户数据）。"
    sh "$root/scripts/uninstall-macos.sh" --keep-user-data
  fi

  echo "正在安装鼠须管，需要输入本机登录密码："
  sudo installer -pkg "$pkg" -target /
  echo "鼠须管 $version 安装完成。"
}

install_squirrel

mkdir -p "$rime_dir"

# 已有的 default.custom.yaml 如果没有启用本方案，备份后替换，备份路径会打印出来
custom="$rime_dir/default.custom.yaml"
if [ -f "$custom" ] && ! grep -q 'wubi86_pinyin' "$custom"; then
  backup="$custom.bak-$(date +%Y%m%d%H%M%S)"
  mv "$custom" "$backup"
  echo "原有的 default.custom.yaml 已备份到 $backup ，其中的其它方案可以自行合并回来。"
elif [ -f "$custom" ]; then
  keep="$custom.keep"
  cp "$custom" "$keep"
fi
"$root/scripts/assemble.sh" "$rime_dir"
if [ -n "${keep:-}" ]; then
  mv "$keep" "$custom"
fi

# 加入系统输入法列表并切换过去：注册 → 启用 → 启动进程 → 部署 → 选中。
# 参数显式给出 Hans 模式，否则鼠须管见到已启用的任意模式就会跳过。
mode="im.rime.inputmethod.Squirrel.Hans"
"$squirrel" --register-input-source >/dev/null 2>&1 || true
"$squirrel" --enable-input-source "$mode" >/dev/null 2>&1 || true

# 刚装完时鼠须管进程还没运行（安装包要求注销），--reload 只通知运行中的进程，
# 什么也不会部署，菜单里也是灰色不可选；所以先在后台启动它，等进程出现再继续
if ! pgrep -x Squirrel >/dev/null 2>&1; then
  open -g "$squirrel_app"
  i=0
  while [ "$i" -lt 15 ] && ! pgrep -x Squirrel >/dev/null 2>&1; do
    sleep 1
    i=$((i + 1))
  done
fi
"$squirrel" --reload

# 已经选中时鼠须管也会输出 Failed，所以再看一下系统当前选中的输入法
selected=$("$squirrel" --select-input-source "$mode" 2>&1 || true)
case "$selected" in
  *succeeds*) switched=1 ;;
  *) defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null \
       | grep -q "$mode" && switched=1 || switched=0 ;;
esac
if [ "$switched" = 1 ]; then
  echo "已安装并切换到鼠须管，可以直接用「五笔86·拼音」打字了。"
  echo "重启后如果鼠须管在菜单里变成灰色，注销后重新登录一次即可。"
else
  echo "已安装并重新部署，但没能自动切换到鼠须管。请在菜单栏的输入法里手动选择；如果是灰色，注销后重新登录一次。"
fi
