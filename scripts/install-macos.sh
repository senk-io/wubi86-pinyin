#!/usr/bin/env sh
# 安装 SENK 输入法程序和方案。按 RULES.md 第 7 节的脚本安全标准编写：
# - 默认只预览：列出检查结果和将要执行的每一步，不做任何改动。加 --apply 才执行，执行前要求输入 yes。
# - 程序从 senk-io/senk-input-macos 的 Release 下载固定版本，校验 sha256 和签名后装到 ~/Library/Input Methods，
#   不需要 sudo。已装的是同一版本时不重装，只更新方案文件并重新部署。
# - 改动前备份 ~/Library/Rime、SENK 的偏好设置和已装的程序；任何一步失败都立即停止并回滚。
# - 退出输入法只用它自带的 --quit；不用 kill、不用 open 启动输入法、不依赖注销。
# - 日志写到 ~/Library/Logs/senk-input/。
#
# 用法：sh scripts/install-macos.sh [--apply] [wubi86-pinyin|pinyin]
#   安装包：wubi86-pinyin 为SENK五笔混拼输入法86版，pinyin 为SENK拼音输入法；不给出时读取根目录的 VARIANT 文件，
#   没有则为 wubi86-pinyin。两个包可以先后都装，在菜单栏的输入法菜单里选「SENK五笔」或「SENK拼音」。
set -u

# 固定版本。改版本时两项一起改，CI 会下载并核对。
senk_version="1.0.1"
senk_sha256="ff432b6a357a312822ba6777b317a57a1908b2e76469f2da589d275c1c7da6ca"
min_macos=13
min_free_mb=500
deploy_timeout=120

root=$(cd "$(dirname "$0")/.." && pwd)
apply=0
variant=""
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    wubi86-pinyin|pinyin) variant=$arg ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（用法：sh scripts/install-macos.sh [--apply] [wubi86-pinyin|pinyin]）" >&2; exit 1 ;;
  esac
done
[ -n "$variant" ] || variant=$(cat "$root/VARIANT" 2>/dev/null || echo wubi86-pinyin)
case "$variant" in
  wubi86-pinyin) schema=wubi86_pinyin schema_name="SENK五笔" test_hint="nihao 和 wqvb 都出「你好」" ;;
  pinyin) schema=senk_pinyin schema_name="SENK拼音" test_hint="nihao 出「你好」" ;;
  *) echo "未知的安装包：${variant}（可选 wubi86-pinyin、pinyin）" >&2; exit 1 ;;
esac

bundle_id="io.senk.inputmethod.SenkWubi"
app="$HOME/Library/Input Methods/SenkWubi.app"
url="https://github.com/senk-io/senk-input-macos/releases/download/v$senk_version/SenkWubi-$senk_version.zip"
rime_dir="$HOME/Library/Rime"
prefs="$HOME/Library/Preferences/$bundle_id.plist"
state_dir="$HOME/Library/Application Support/senk-input"
log_dir="$HOME/Library/Logs/senk-input"
stamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$state_dir/backup-$stamp"
lock_dir="$state_dir/install.lock"
rime_log_dir="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}/")rime.senk"
log_file=""

# 回滚需要知道做到了哪一步
lock_held=0
rime_changed=0
rime_existed=0
app_saved=0      # 原来的程序已打包进备份并移走
app_installed=0  # 新程序已放到 $app
registered=0     # 本次新注册了输入源
tmp=""

log() {
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  [ -z "$log_file" ] || printf '%s\n' "$line" >>"$log_file"
}

cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ "$lock_held" = 0 ] || rmdir "$lock_dir" 2>/dev/null
}
trap cleanup EXIT

plist() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
# 可执行文件名从 Info.plist 读，旧版本的程序也能正确退出
senk_bin() { exe=$(plist "$app" CFBundleExecutable) && printf '%s\n' "$app/Contents/MacOS/$exe"; }
senk_running() { pgrep -f "^$app/Contents/MacOS/" >/dev/null 2>&1; }
senk() { bin=$(senk_bin) || return 1; "$bin" "$@" >>"${log_file:-/dev/null}" 2>&1; }

# 输入源 ID：程序的 Bundle ID 加模式名。schema 在 Rime 目录里存在时才启用对应模式
mode_of() { case "$1" in wubi86_pinyin) echo "$bundle_id.Wubi" ;; senk_pinyin) echo "$bundle_id.Pinyin" ;; esac; }
# 输入源在系统输入法服务里的状态：enabled、disabled、absent，查不到时为 unknown。
# 不看 com.apple.HIToolbox 偏好文件，它可能和实际状态不一致（见 scripts/input-source-state.js）
source_state() {
  state=$(osascript -l JavaScript "$root/scripts/input-source-state.js" "$1" 2>/dev/null) || state=unknown
  case "$state" in enabled|disabled|absent) ;; *) state=unknown ;; esac
  printf '%s\n' "$state"
}
# 等到输入源状态满足条件：wait_state <输入源> <enabled|present> <秒>
wait_state() {
  i=0
  while [ "$i" -lt "$3" ]; do
    s=$(source_state "$1")
    case "$2:$s" in enabled:enabled|present:enabled|present:disabled) return 0 ;; esac
    sleep 1
    i=$((i + 1))
  done
  return 1
}
# 最近一次部署完成的时间（user.yaml 的 var/last_build_time），没有时为空
build_time() { sed -n 's/^ *last_build_time: *\([0-9][0-9]*\).*/\1/p' "$rime_dir/user.yaml" 2>/dev/null | head -n 1; }
wait_quit() {
  i=0
  while [ "$i" -lt 15 ]; do
    senk_running || return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

rollback() {
  log "回滚：开始"
  if [ "$app_installed" = 1 ]; then
    if senk_running; then senk --quit; wait_quit || log "回滚：SENK 没有在 15 秒内退出"; fi
    [ "$registered" = 0 ] || senk --disable-input-source
    failed="$state_dir/failed-$stamp"
    if mkdir -p "$failed" && mv "$app" "$failed/"; then
      log "回滚：新装的程序已移到 $failed"
    else
      log "回滚：无法移走 ${app}。请手动运行：mv \"$app\" \"$failed/\""
    fi
  fi
  if [ "$app_saved" = 1 ]; then
    if ditto -x -k "$backup_dir/SenkWubi.app.zip" "$(dirname "$app")"; then
      log "回滚：已恢复原来的程序"
    else
      log "回滚：恢复程序失败。请手动运行：ditto -x -k \"$backup_dir/SenkWubi.app.zip\" \"$(dirname "$app")\""
    fi
  fi
  if [ "$rime_changed" = 1 ]; then
    # 不删除任何东西：改动过的目录改名留存，再从备份恢复
    failed="$rime_dir.failed-$stamp"
    if mv "$rime_dir" "$failed"; then
      log "回滚：改动后的 Rime 目录已移到 $failed"
      if [ "$rime_existed" = 1 ]; then
        if ditto "$backup_dir/Rime" "$rime_dir"; then
          log "回滚：已从 $backup_dir/Rime 恢复 $rime_dir"
        else
          log "回滚：恢复失败。请手动运行：ditto \"$backup_dir/Rime\" \"$rime_dir\""
        fi
      fi
      if senk_running; then senk --reload && log "回滚：已通知 SENK 按恢复后的文件重新部署"; fi
    else
      log "回滚：无法移动 ${rime_dir}。备份在 $backup_dir/Rime，请手动恢复"
    fi
  fi
  log "回滚：结束"
}

fail() {
  log "失败：$*"
  rollback
  log "已停止。日志：$log_file"
  exit 1
}

# ---------- 前置检查（预览和执行都做，不改动任何东西） ----------
problems=0
check() {  # check <是否通过 0/1> <说明>
  if [ "$1" = 0 ]; then echo "  [通过] $2"; else echo "  [不通过] $2"; problems=$((problems + 1)); fi
}

# 发布包里由 git archive 替换为提交号
# shellcheck disable=SC2016
script_version='$Format:%h$'
echo "SENK 输入法安装脚本（版本 ${script_version}），安装包：${variant}（方案「${schema_name}」）"
if [ "$apply" = 1 ]; then echo "模式：执行"; else echo "模式：预览（不做任何改动；确认无误后加 --apply 执行）"; fi
echo
echo "前置检查："

os_version=$(sw_vers -productVersion 2>/dev/null || echo 0)
[ "${os_version%%.*}" -ge "$min_macos" ] 2>/dev/null; check $? "macOS ${os_version}（需要 $min_macos 或更高）"

free_mb=$(df -Pk "$HOME" | awk 'NR == 2 { print int($4 / 1024) }')
[ "${free_mb:-0}" -ge "$min_free_mb" ]; check $? "可用磁盘空间 ${free_mb}MB（需要 ${min_free_mb}MB）"

pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")
[ "$pressure" = 1 ]; check $? "内存压力等级 ${pressure}（必须为 1，即正常；黄或红时不安装）"

busy=0
[ ! -d "$lock_dir" ] || busy=1
if pgrep -x installer >/dev/null 2>&1; then busy=1; fi
[ "$busy" = 0 ]; check $? "没有其它安装正在进行（$lock_dir 不存在，没有 installer 进程）"

[ -f "$root/schema/$schema.schema.yaml" ]; check $? "方案文件 schema/$schema.schema.yaml 存在"

installed=""
if [ -d "$app" ]; then
  [ "$(plist "$app" CFBundleIdentifier)" = "$bundle_id" ]; check $? "$app 是 SENK（${bundle_id}）"
  installed=$(plist "$app" CFBundleVersion || echo "未知")
  if [ "$installed" = "$senk_version" ]; then
    echo "  [信息] 已安装 SENK ${installed}：不重装"
  else
    echo "  [信息] 已安装 SENK ${installed}：将换成 $senk_version"
  fi
else
  echo "  [信息] 未安装 SENK：将安装 $senk_version"
fi
if senk_running; then echo "  [信息] SENK 正在运行"; else echo "  [信息] SENK 没有运行"; fi

if [ "$apply" = 1 ] && [ ! -r /dev/tty ]; then
  check 1 "执行模式需要在终端里运行（要输入 yes 确认）"
fi

echo
if [ "$problems" -gt 0 ]; then
  echo "有 $problems 项检查不通过，已退出，没有做任何改动。"
  exit 1
fi

# ---------- 计划 ----------
echo "将要执行的步骤："
echo "  1. 备份 $rime_dir 和 $prefs 到 $backup_dir"
if [ "$installed" != "$senk_version" ]; then
  echo "  2. 下载 SENK ${senk_version}（${url}），校验 sha256 ($senk_sha256) 和签名（标识 ${bundle_id}）"
  [ -z "$installed" ] || echo "     用 --quit 退出正在运行的 SENK，把原来的程序打包进备份后移走"
  echo "     装到 ${app}（不需要 sudo）"
else
  echo "  2. 程序已是 ${senk_version}，跳过"
fi
echo "  3. 把方案「${schema_name}」的文件复制到 ${rime_dir}（default.custom.yaml 的处理规则见脚本注释）"
echo "  4. 在系统里注册并启用 SENK 的输入法（已装方案对应的「SENK五笔」「SENK拼音」），选中「${schema_name}」"
echo "     系统不让脚本自动启用时，提示你在系统设置里添加，添加好后按回车继续"
echo "  5. 再查一次内存压力，然后通知 SENK 重新部署，等待部署结果（最多 ${deploy_timeout} 秒）"
echo "     SENK 没有运行时不部署，也不手动启动它，文件会在它下次启动时生效"
echo "  6. 验证：SENK 在运行、部署出的方案文件存在、输入法已启用"
echo
echo "任何一步失败都会停止并回滚：恢复 ${rime_dir} 和原来的程序。"
echo "日志写到 $log_dir/install-$stamp.log"

if [ "$apply" = 0 ]; then
  echo
  echo "以上是预览，没有做任何改动。确认后运行：sh scripts/install-macos.sh --apply $variant"
  exit 0
fi

echo
printf "确认执行以上步骤？输入 yes 继续，其它任何输入都会退出："
read -r answer </dev/tty
if [ "$answer" != yes ]; then
  echo "已取消，没有做任何改动。"
  exit 1
fi

# ---------- 执行 ----------
mkdir -p "$state_dir" "$log_dir" || { echo "无法创建 $state_dir 或 ${log_dir}，已停止，没有做任何改动。" >&2; exit 1; }
log_file="$log_dir/install-$stamp.log"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "另一个安装正在进行（$lock_dir 已存在），已停止，没有做任何改动。" >&2
  exit 1
fi
lock_held=1
log "开始安装：安装包 ${variant}，macOS ${os_version}，内存压力 ${pressure}，已装 SENK ${installed:-无}"

# 1. 备份
mkdir -p "$backup_dir" || fail "无法创建备份目录 $backup_dir"
if [ -d "$rime_dir" ]; then
  rime_existed=1
  ditto "$rime_dir" "$backup_dir/Rime" || fail "备份 $rime_dir 失败"
fi
if [ -f "$prefs" ]; then
  cp "$prefs" "$backup_dir/" || fail "备份 $prefs 失败"
fi
log "第 1 步完成：已备份到 $backup_dir"

# 2. 安装程序（没装或版本不同时）
if [ "$installed" != "$senk_version" ]; then
  tmp=$(mktemp -d) || fail "无法创建临时目录"
  zip="$tmp/SenkWubi-$senk_version.zip"
  log "下载 $url"
  curl -fL --progress-bar -o "$zip" "$url" || fail "下载失败"
  actual=$(shasum -a 256 "$zip" | awk '{ print $1 }')
  [ "$actual" = "$senk_sha256" ] || fail "sha256 不符：期望 ${senk_sha256}，实际 $actual"
  log "sha256 校验通过"
  ditto -x -k "$zip" "$tmp/x" >>"$log_file" 2>&1 || fail "无法解压"
  new="$tmp/x/SenkWubi.app"
  [ -d "$new" ] || fail "压缩包里没有 SenkWubi.app"
  # 程序是临时签名（ad-hoc），签名只证明内容完整；来源由上面固定的 sha256 保证
  codesign --verify --deep --strict "$new" >>"$log_file" 2>&1 || fail "签名校验失败（见日志）"
  ident=$(codesign -dv "$new" 2>&1 | sed -n 's/^Identifier=//p')
  [ "$ident" = "$bundle_id" ] || fail "签名标识不符：期望 ${bundle_id}，实际 ${ident:-无}"
  [ "$(plist "$new" CFBundleVersion)" = "$senk_version" ] || fail "压缩包里的程序版本不是 $senk_version"
  log "签名校验通过（Identifier=${ident}）"
  if [ -n "$installed" ]; then
    if senk_running; then
      senk --quit || fail "--quit 失败（见日志）"
      wait_quit || fail "SENK 没有在 15 秒内退出（不会强制结束）"
      log "已退出正在运行的 SENK"
    fi
    (cd "$(dirname "$app")" && ditto -c -k --keepParent SenkWubi.app "$backup_dir/SenkWubi.app.zip") \
      || fail "备份原来的程序失败"
    rm -rf "$app" || fail "无法移走原来的程序"
    app_saved=1
    log "原来的程序 ${installed} 已打包到 $backup_dir/SenkWubi.app.zip"
  fi
  mkdir -p "$(dirname "$app")" || fail "无法创建 $(dirname "$app")"
  app_installed=1
  ditto "$new" "$app" || fail "复制程序失败"
  log "第 2 步完成：已安装 SENK $senk_version 到 $app"
fi
senk_bin >/dev/null || fail "没有找到 SENK 的可执行文件"

# 3. 复制方案文件
# default.custom.yaml：本脚本生成的直接重新生成；用户自己的如果已启用本方案就保留，
# 否则替换（原文件在第 1 步的备份里）
rime_changed=1
mkdir -p "$rime_dir" || fail "无法创建 $rime_dir"
custom="$rime_dir/default.custom.yaml"
keep=0
if [ -f "$custom" ] && ! head -n 1 "$custom" | grep -q 'wubi86-pinyin' && grep -q "$schema" "$custom"; then
  keep=1
fi
"$root/scripts/assemble.sh" "$rime_dir" "$variant" >>"$log_file" 2>&1 || fail "复制方案文件失败（见日志）"
if [ "$keep" = 1 ]; then
  cp "$backup_dir/Rime/default.custom.yaml" "$custom" || fail "恢复你自己的 default.custom.yaml 失败"
  log "保留了你自己的 default.custom.yaml（其中已启用 ${schema}）"
elif [ -f "$backup_dir/Rime/default.custom.yaml" ]; then
  log "原有的 default.custom.yaml 已替换，原文件在 $backup_dir/Rime/default.custom.yaml"
fi
log "第 3 步完成：方案文件已复制到 $rime_dir"

# 4. 注册、启用、选中输入法
primary=$(mode_of "$schema")
modes=""
for s in wubi86_pinyin senk_pinyin; do
  [ ! -f "$rime_dir/$s.schema.yaml" ] || modes="$modes $(mode_of "$s")"
done
if [ "$(source_state "$primary")" = absent ]; then
  senk --register-input-source || fail "--register-input-source 失败（见日志）"
  registered=1
  wait_state "$primary" present 15 || fail "注册后 15 秒内系统里仍然没有 $primary"
fi
# 启用要看系统「已启用」列表（source_state），不看输入模式自己的 IsEnabled：带模式的输入法本体没启用时，
# 模式的 IsEnabled 可能仍为 1。macOS 26 上实测：程序调用 TISEnableInputSource 启用输入法本体返回成功但不生效，
# 只能由用户在系统设置里添加。所以自动启用不成功时请用户添加，不当作安装失败
all_enabled() {
  for m in $modes; do [ "$(source_state "$m")" = enabled ] || return 1; done
}
# shellcheck disable=SC2086  # modes 是空格分隔的输入源列表
senk --enable-input-source $modes || log "注意：--enable-input-source 返回错误（见日志）"
i=0
while [ "$i" -lt 5 ] && ! all_enabled; do
  sleep 1
  i=$((i + 1))
done
if ! all_enabled; then
  log "第 4 步：系统没有让脚本自动启用 SENK 的输入法，需要你手动添加（只需一次）："
  echo "  打开「系统设置 → 键盘 → 输入法」，点「编辑…」，左下角点「+」，选「简体中文」，"
  echo "  添加「SENK五笔」$( [ "${modes#*Pinyin}" = "$modes" ] || echo "和「SENK拼音」")。列表里没有 SENK 时，注销并重新登录一次后再添加。"
  printf "添加好后按回车继续（暂时不添加也按回车，安装照常完成，之后再添加即可）："
  read -r _ </dev/tty
fi
selected=0
if [ "$(source_state "$primary")" = enabled ]; then
  senk --select-input-source "$primary" || fail "--select-input-source 失败（见日志）"
  selected=1
  log "第 4 步完成：已启用并选中 $primary"
else
  log "第 4 步：$primary 还没有启用，跳过选中。添加后在菜单栏的输入法菜单里选「${schema_name}」即可"
fi

# 5. 重新部署。系统在选中输入法后会启动 SENK，最多等 15 秒
i=0
while [ "$selected" = 1 ] && [ "$i" -lt 15 ] && ! senk_running; do
  sleep 1
  i=$((i + 1))
done
deployed=0
if ! senk_running; then
  log "第 5 步：SENK 没有运行，不部署。本脚本不会手动启动输入法。"
  log "  文件已就位：在菜单栏的输入法菜单里选「${schema_name}」后，SENK 启动时会自动部署。"
else
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")
  [ "$pressure" = 1 ] || fail "内存压力等级变为 ${pressure}，不部署"
  # 部署完成的标志是 user.yaml 里的 var/last_build_time 变了：每次部署结束都会更新它（精确到秒）。
  # 不看 build/ 下文件的时间：文件没有变化时重新部署不会重写它们（SENK 刚启动时已经编译过）。
  # 也不看 Rime 日志：它的 INFO 行有缓冲，可能迟迟不写出
  build_before=$(build_time)
  errors_before=0
  [ ! -f "$rime_log_dir/rime.senk.ERROR" ] || errors_before=$(wc -l <"$rime_log_dir/rime.senk.ERROR")
  sleep 1  # 让这次部署的完成时间晚于上次，避免两次落在同一秒
  senk --reload || fail "--reload 失败（见日志）"
  log "已通知 SENK 重新部署，等待结果"
  i=0
  done_all=0
  while [ "$i" -lt "$deploy_timeout" ]; do
    now=$(build_time)
    if [ -n "$now" ] && [ "$now" != "$build_before" ]; then done_all=1; break; fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$done_all" = 0 ]; then
    # 部署可能还在进行，这时恢复文件会和它冲突，所以只停止并报告，不自动回滚
    log "停止：${deploy_timeout} 秒内部署没有完成。没有自动回滚（部署可能仍在进行）。"
    log "  请看 SENK 日志 ${rime_log_dir}；如需回滚：mv \"$rime_dir\" \"$rime_dir.failed-$stamp\" && ditto \"$backup_dir/Rime\" \"$rime_dir\"，然后在 SENK 菜单里选「重新部署」"
    exit 1
  fi
  if [ -f "$rime_log_dir/rime.senk.ERROR" ]; then
    new_errors=$(tail -n +"$((errors_before + 1))" "$rime_log_dir/rime.senk.ERROR")
    [ -z "$new_errors" ] || log "注意：部署期间 Rime 记录了错误（不一定影响使用）：$new_errors"
  fi
  deployed=1
  log "第 5 步完成：部署完成"
fi

# 6. 验证
if [ "$deployed" = 1 ]; then
  senk_running || fail "部署后 SENK 不在运行"
  [ -f "$rime_dir/build/$schema.schema.yaml" ] || fail "没有找到部署出的 build/$schema.schema.yaml"
fi
if [ "$selected" = 1 ]; then
  log "第 6 步完成：验证通过"
else
  log "第 6 步完成：文件和程序已就位；「${schema_name}」还没有添加到输入法，添加后即可使用"
fi
log "安装完成。备份在 ${backup_dir}，日志在 $log_file"
echo
echo "请在菜单栏的输入法菜单里选「${schema_name}」，确认打 ${test_hint}。"
