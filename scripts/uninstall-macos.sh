#!/usr/bin/env sh
# 卸载鼠须管（Squirrel），清理应用、安装记录、输入源和偏好设置。
# Rime 用户目录 ~/Library/Rime（含词频记录）需要确认后才删除。
#
# 用法：sh scripts/uninstall-macos.sh [--keep-user-data]
#   --keep-user-data  保留 ~/Library/Rime，不询问（重新安装时使用）
set -u
keep_user_data=0
[ "${1:-}" = "--keep-user-data" ] && keep_user_data=1
squirrel_app="/Library/Input Methods/Squirrel.app"
squirrel="$squirrel_app/Contents/MacOS/Squirrel"
bundle_id="im.rime.inputmethod.Squirrel"

# 先从系统输入源里移除，再结束进程
if [ -x "$squirrel" ]; then
  "$squirrel" --disable-input-source >/dev/null 2>&1 || true
fi
killall Squirrel >/dev/null 2>&1 || true

echo "需要输入本机登录密码来删除系统目录中的文件："
sudo rm -rf "$squirrel_app"
sudo pkgutil --forget "$bundle_id" >/dev/null 2>&1 || true

rm -rf "$HOME/Library/Caches/$bundle_id" \
       "$HOME/Library/HTTPStorages/$bundle_id" \
       "$HOME/Library/Preferences/$bundle_id.plist"

rime_dir="$HOME/Library/Rime"
if [ "$keep_user_data" = 1 ]; then
  echo "已保留 $rime_dir"
elif [ -d "$rime_dir" ]; then
  echo "发现 Rime 用户目录 ${rime_dir}，内容如下："
  ls "$rime_dir"
  printf "是否一并删除？其中包括你的词频记录 [y/N] "
  read -r answer
  case "$answer" in
    y|Y) rm -rf "$rime_dir"; echo "已删除 $rime_dir" ;;
    *) echo "已保留 $rime_dir" ;;
  esac
fi

if [ "$keep_user_data" = 1 ]; then
  echo "旧版鼠须管已卸载。"
else
  echo "卸载完成。请注销后重新登录，让输入法菜单刷新。"
fi
