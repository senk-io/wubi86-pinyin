#!/usr/bin/env sh
# 安装到鼠须管（Squirrel）用户目录并重新部署；没装鼠须管时先自动安装。
#
# 用法：sh scripts/install-macos.sh
# 环境变量：
#   SQUIRREL_VERSION  指定鼠须管版本（如 1.1.2），默认取 GitHub 上的最新正式版
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
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
    *) echo "无法确定鼠须管版本（得到：$version），可用 SQUIRREL_VERSION=1.1.2 指定。" >&2; exit 1 ;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  pkg="$tmp/Squirrel-$version.pkg"
  echo "正在下载鼠须管 $version ..."
  curl -fL --progress-bar -o "$pkg" "$releases/download/$version/Squirrel-$version.pkg"

  echo "正在安装鼠须管，需要输入本机登录密码："
  sudo installer -pkg "$pkg" -target /

  # 上游的应用使用 Developer ID 签名；签名校验不通过就停下，不继续写入配置
  if ! codesign --verify --deep --strict "$squirrel_app" 2>/dev/null; then
    echo "鼠须管签名校验失败，已停止。请到 $releases 手动下载安装。" >&2
    exit 1
  fi
  echo "鼠须管 $version 安装完成。"
}

if [ ! -x "$squirrel" ]; then
  install_squirrel
fi

mkdir -p "$rime_dir"

# 不覆盖用户已有的 default.custom.yaml，避免丢掉其它方案
keep=""
if [ -f "$rime_dir/default.custom.yaml" ]; then
  keep="$rime_dir/default.custom.yaml.keep"
  cp "$rime_dir/default.custom.yaml" "$keep"
fi
"$root/scripts/assemble.sh" "$rime_dir"
if [ -n "$keep" ]; then
  mv "$keep" "$rime_dir/default.custom.yaml"
  echo "保留了你原有的 default.custom.yaml，请在 schema_list 中加入：- schema: wubi86_pinyin"
fi

"$squirrel" --enable-input-source >/dev/null 2>&1 || true
"$squirrel" --reload
echo "已安装并重新部署。请在菜单栏的输入法里选「鼠须管」，就能用「五笔86·拼音」打字了。"
echo "如果菜单栏里还看不到鼠须管，请注销后重新登录一次。"
