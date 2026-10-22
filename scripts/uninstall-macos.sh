#!/usr/bin/env sh
# 卸载 SENK 输入法程序。按 RULES.md 第 7 节的脚本安全标准编写：
# - 默认只预览，加 --apply 才执行，执行前要求输入 yes。
# - 改动前把程序、偏好设置和 ~/Library/Rime 备份到 ~/Library/Application Support/senk-input/。
# - 退出输入法只用它自带的 --quit，不用 kill；不需要 sudo。
# - ~/Library/Rime（含词频记录）默认保留，加 --remove-user-data 才删除（备份仍会保留）。
# - 不删除 ~/Library/Logs/senk-input/ 下的日志，不卸载其它程序。
#
# 用法：sh scripts/uninstall-macos.sh [--apply] [--remove-user-data]
set -u
apply=0
remove_user_data=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    --remove-user-data) remove_user_data=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（用法：sh scripts/uninstall-macos.sh [--apply] [--remove-user-data]）" >&2; exit 1 ;;
  esac
done

bundle_id="io.senk.inputmethod.SenkWubi"
app="$HOME/Library/Input Methods/SenkWubi.app"
rime_dir="$HOME/Library/Rime"
prefs="$HOME/Library/Preferences/$bundle_id.plist"
state_dir="$HOME/Library/Application Support/senk-input"
log_dir="$HOME/Library/Logs/senk-input"
stamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$state_dir/uninstall-$stamp"
log_file=""

log() {
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  [ -z "$log_file" ] || printf '%s\n' "$line" >>"$log_file"
}
fail() {
  log "失败：$*"
  log "已停止。已做的改动可以从 $backup_dir 恢复，日志：$log_file"
  exit 1
}

senk_bin() {
  exe=$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist" 2>/dev/null) && printf '%s\n' "$app/Contents/MacOS/$exe"
}
senk_running() { pgrep -f "^$app/Contents/MacOS/" >/dev/null 2>&1; }
senk() { bin=$(senk_bin) || return 1; "$bin" "$@" >>"${log_file:-/dev/null}" 2>&1; }

# 旧版本（v0.5.0 及以前）的本地模型常驻进程 wubi86d 已移除，它留下的东西一并清理（不涉及词频等打字数据）
label="io.senk.wubi86d"
old_files="$HOME/Library/LaunchAgents/${label}.plist $rime_dir/wubi86d $rime_dir/lua/wubi_predict.lua $rime_dir/lua/wubi_predict_switch.lua $rime_dir/lua/pinyin_filter.lua"
caches="$HOME/Library/Caches/$bundle_id $HOME/Library/HTTPStorages/$bundle_id"

echo "SENK 输入法卸载脚本"
if [ "$apply" = 1 ]; then echo "模式：执行"; else echo "模式：预览（不做任何改动；确认无误后加 --apply 执行）"; fi
echo
echo "将要执行的步骤："
echo "  1. 把程序、偏好设置和 $rime_dir 备份到 $backup_dir"
if [ -d "$app" ]; then
  echo "  2. 在系统里停用 SENK 的输入法，用 --quit 退出 SENK，删除 $app"
else
  echo "  2. 没有找到 ${app}，跳过"
fi
echo "  3. 删除偏好设置和缓存：${prefs}、$HOME/Library/Caches/${bundle_id}、$HOME/Library/HTTPStorages/$bundle_id"
echo "  4. 清理旧版本留下的 wubi86d（如果有）"
if [ "$remove_user_data" = 1 ]; then
  echo "  5. 删除 ${rime_dir}（含词频记录；备份里留有一份）"
else
  echo "  5. 保留 ${rime_dir}（要删除时加 --remove-user-data）"
fi
echo "日志写到 $log_dir/uninstall-$stamp.log；不删除任何日志。"

if [ "$apply" = 0 ]; then
  echo
  echo "以上是预览，没有做任何改动。确认后运行：sh scripts/uninstall-macos.sh --apply"
  exit 0
fi
if [ ! -r /dev/tty ]; then
  echo "执行模式需要在终端里运行（要输入 yes 确认），已退出，没有做任何改动。" >&2
  exit 1
fi
echo
printf "确认执行以上步骤？输入 yes 继续，其它任何输入都会退出："
read -r answer </dev/tty
if [ "$answer" != yes ]; then
  echo "已取消，没有做任何改动。"
  exit 1
fi

mkdir -p "$backup_dir" "$log_dir" || { echo "无法创建 $backup_dir 或 ${log_dir}，已停止，没有做任何改动。" >&2; exit 1; }
log_file="$log_dir/uninstall-$stamp.log"
log "开始卸载"

# 1. 备份
if [ -d "$app" ]; then
  (cd "$(dirname "$app")" && ditto -c -k --keepParent SenkWubi.app "$backup_dir/SenkWubi.app.zip") || fail "备份程序失败"
fi
[ ! -f "$prefs" ] || cp "$prefs" "$backup_dir/" || fail "备份 $prefs 失败"
[ ! -d "$rime_dir" ] || ditto "$rime_dir" "$backup_dir/Rime" || fail "备份 $rime_dir 失败"
log "第 1 步完成：已备份到 $backup_dir"

# 2. 停用、退出、删除程序
if [ -d "$app" ]; then
  senk --disable-input-source || log "注意：--disable-input-source 返回错误（见日志），继续"
  if senk_running; then
    senk --quit || fail "--quit 失败（见日志）"
    i=0
    while [ "$i" -lt 15 ] && senk_running; do
      sleep 1
      i=$((i + 1))
    done
    senk_running && fail "SENK 没有在 15 秒内退出（不会强制结束）。请先在菜单栏切换到别的输入法，再重新运行"
  fi
  rm -rf "$app" || fail "删除 $app 失败"
  log "第 2 步完成：已删除 $app"
fi

# 3. 偏好设置和缓存
defaults delete "$bundle_id" >/dev/null 2>&1 || true
# shellcheck disable=SC2086  # caches 是空格分隔的路径，均不含空格
rm -rf "$prefs" $caches || fail "删除偏好设置或缓存失败"
log "第 3 步完成：已删除偏好设置和缓存"

# 4. 旧版本的 wubi86d
launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
# shellcheck disable=SC2086  # old_files 是空格分隔的路径，均不含空格
rm -rf $old_files || fail "清理 wubi86d 失败"
log "第 4 步完成"

# 5. Rime 用户目录
if [ "$remove_user_data" = 1 ] && [ -d "$rime_dir" ]; then
  rm -rf "$rime_dir" || fail "删除 $rime_dir 失败"
  log "第 5 步完成：已删除 ${rime_dir}，备份在 $backup_dir/Rime"
else
  log "第 5 步：保留 $rime_dir"
fi

log "卸载完成。备份在 ${backup_dir}，日志在 $log_file"
echo "如果装过旧版的本地模型，Ollama 和模型没有删除（其它程序也可能在用）；如需删除：brew uninstall ollama && rm -rf ~/.ollama"
