#!/usr/bin/env sh
# 把本方案装进鼠须管（Squirrel）。按 RULES.md 第 7 节的脚本安全标准编写：
# - 默认只预览：列出检查结果和将要执行的每一步，不做任何改动。加 --apply 才执行，执行前要求输入 yes。
# - 已经装了鼠须管时不卸载、不重装、不结束进程，只更新方案文件并通知它重新部署。
# - 没装时从官方 Release 下载固定版本，校验 sha256 和签名后再安装。
# - 改动前备份 ~/Library/Rime 和鼠须管的偏好设置；任何一步失败都立即停止并回滚。
# - 不用 kill、不用 open 启动输入法、不依赖注销；系统确实需要注销时，说明原因后停下，由用户决定。
# - 日志写到 ~/Library/Logs/senk-input/。
#
# 用法：sh scripts/install-macos.sh [--apply] [wubi86-pinyin|pinyin]
#   安装包：wubi86-pinyin 为五笔86·拼音混输，pinyin 为纯拼音；不给出时读取根目录的 VARIANT 文件，
#   没有则为 wubi86-pinyin。两个包可以先后都装，方案菜单（Control+`）里切换。
set -u

# 固定版本。改版本时三项一起改，CI 会下载并核对。
squirrel_version="1.1.2"
squirrel_sha256="614746013212937623d5bbab9901e9c43d1ec937aa32307d6b6092a05e308287"
squirrel_team_id="28HU5A7B46"  # 上游维护者的 Developer ID：Yuncao Liu
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
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（用法：sh scripts/install-macos.sh [--apply] [wubi86-pinyin|pinyin]）" >&2; exit 1 ;;
  esac
done
[ -n "$variant" ] || variant=$(cat "$root/VARIANT" 2>/dev/null || echo wubi86-pinyin)
case "$variant" in
  wubi86-pinyin) schema=wubi86_pinyin schema_name="五笔86·拼音" test_hint="nihao 和 wqvb 都出「你好」" ;;
  pinyin) schema=senk_pinyin schema_name="拼音" test_hint="nihao 出「你好」" ;;
  *) echo "未知的安装包：${variant}（可选 wubi86-pinyin、pinyin）" >&2; exit 1 ;;
esac

rime_dir="$HOME/Library/Rime"
squirrel_app="/Library/Input Methods/Squirrel.app"
squirrel="$squirrel_app/Contents/MacOS/Squirrel"
bundle_id="im.rime.inputmethod.Squirrel"
input_mode="$bundle_id.Hans"
prefs="$HOME/Library/Preferences/$bundle_id.plist"
state_dir="$HOME/Library/Application Support/senk-input"
log_dir="$HOME/Library/Logs/senk-input"
stamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$state_dir/backup-$stamp"
lock_dir="$state_dir/install.lock"
rime_log="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}/")rime.squirrel/rime.squirrel.INFO"
log_file=""

# 回滚需要知道做到了哪一步
lock_held=0
rime_changed=0
rime_existed=0
source_enabled_by_us=0
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

squirrel_running() { pgrep -x Squirrel >/dev/null 2>&1; }
source_enabled() {
  defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null | grep -q "$bundle_id"
}

rollback() {
  log "回滚：开始"
  if [ "$source_enabled_by_us" = 1 ]; then
    if "$squirrel" --disable-input-source >>"$log_file" 2>&1; then
      log "回滚：已从系统输入法列表移除鼠须管（本次是脚本加进去的）"
    else
      log "回滚：移除输入法失败，请在「系统设置 → 键盘 → 输入法」里手动移除鼠须管"
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
      if squirrel_running; then
        "$squirrel" --reload >>"$log_file" 2>&1 && log "回滚：已通知鼠须管按恢复后的文件重新部署"
      fi
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
echo "wubi86-pinyin 安装脚本（版本 ${script_version}），安装包：${variant}（方案「${schema_name}」）"
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

if [ -x "$squirrel" ]; then
  installed=$(defaults read "$squirrel_app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "未知")
  echo "  [信息] 已安装鼠须管 ${installed}：不会卸载或重装"
else
  installed=""
  echo "  [信息] 未安装鼠须管：将安装固定版本 $squirrel_version"
fi
if squirrel_running; then echo "  [信息] 鼠须管进程正在运行"; else echo "  [信息] 鼠须管进程没有运行"; fi
if source_enabled; then echo "  [信息] 鼠须管已在系统输入法列表里"; else echo "  [信息] 鼠须管不在系统输入法列表里"; fi

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
n=1
echo "  $n. 备份 $rime_dir 和 $prefs 到 $backup_dir"
n=$((n + 1))
if [ -z "$installed" ]; then
  echo "  $n. 下载鼠须管 ${squirrel_version}，校验 sha256 ($squirrel_sha256) 和签名（TeamIdentifier=${squirrel_team_id}），用 sudo installer 安装（需要输入登录密码）"
  n=$((n + 1))
fi
echo "  $n. 把方案「${schema_name}」的文件复制到 ${rime_dir}（default.custom.yaml 的处理规则见脚本注释）"
n=$((n + 1))
echo "  $n. 如果鼠须管不在系统输入法列表里，用它自带的 --register-input-source / --enable-input-source 加入"
n=$((n + 1))
echo "  $n. 再查一次内存压力，然后用 --reload 通知鼠须管重新部署，等待部署结果（最多 ${deploy_timeout} 秒）"
echo "     鼠须管进程没有运行时不部署，也不手动启动它，文件会在它下次启动时生效"
n=$((n + 1))
echo "  $n. 验证：鼠须管进程在运行、在系统输入法列表里、部署出的方案文件存在"
echo
echo "任何一步失败都会停止并回滚：恢复 ${rime_dir}、撤销本次加入的输入法。"
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
log "开始安装：安装包 ${variant}，macOS ${os_version}，内存压力 ${pressure}，已装鼠须管 ${installed:-无}"

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

# 2. 安装鼠须管（只在没装时）
if [ -z "$installed" ]; then
  tmp=$(mktemp -d) || fail "无法创建临时目录"
  pkg="$tmp/Squirrel-$squirrel_version.pkg"
  url="https://github.com/rime/squirrel/releases/download/$squirrel_version/Squirrel-$squirrel_version.pkg"
  log "下载 $url"
  curl -fL --progress-bar -o "$pkg" "$url" || fail "下载失败"
  actual=$(shasum -a 256 "$pkg" | awk '{ print $1 }')
  [ "$actual" = "$squirrel_sha256" ] || fail "sha256 不符：期望 ${squirrel_sha256}，实际 $actual"
  log "sha256 校验通过"
  # 安装前校验包内应用的签名。不能装完再验：安装包的 postinstall 会在
  # Squirrel.app 内部生成预编译数据，之后整包签名校验必然失败。
  pkgutil --expand-full "$pkg" "$tmp/expanded" >>"$log_file" 2>&1 || fail "无法展开安装包"
  app=$(find "$tmp/expanded" -type d -name Squirrel.app -prune | head -n 1)
  [ -n "$app" ] || fail "安装包里没有找到 Squirrel.app"
  codesign --verify --deep --strict "$app" >>"$log_file" 2>&1 || fail "签名校验失败（见日志）"
  team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$team" = "$squirrel_team_id" ] || fail "签名者不符：期望 ${squirrel_team_id}，实际 ${team:-无}"
  log "签名校验通过（TeamIdentifier=${team}）"
  echo "正在安装鼠须管，需要输入本机登录密码："
  # 日志由当前用户写入，有意不让 sudo 管重定向
  # shellcheck disable=SC2024
  if ! sudo installer -pkg "$pkg" -target / >>"$log_file" 2>&1; then
    log "失败：installer 返回错误（见日志）。如果鼠须管只装了一半，可以手动移除："
    log "  sudo rm -rf \"$squirrel_app\" && sudo pkgutil --forget $bundle_id"
    fail "安装鼠须管失败"
  fi
  [ -x "$squirrel" ] || fail "安装后没有找到 $squirrel"
  log "第 2 步完成：已安装鼠须管 $squirrel_version"
  log "  如需撤销这一步：sudo rm -rf \"$squirrel_app\" && sudo pkgutil --forget $bundle_id"
fi

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

# 4. 加入系统输入法列表
if source_enabled; then
  log "第 4 步：鼠须管已在系统输入法列表里，跳过"
else
  source_enabled_by_us=1
  "$squirrel" --register-input-source >>"$log_file" 2>&1 || fail "注册输入法失败（见日志）"
  "$squirrel" --enable-input-source "$input_mode" >>"$log_file" 2>&1 || fail "启用输入法失败（见日志）"
  i=0
  while [ "$i" -lt 10 ] && ! source_enabled; do sleep 1; i=$((i + 1)); done
  source_enabled || fail "鼠须管仍不在系统输入法列表里"
  log "第 4 步完成：已把鼠须管加入系统输入法列表"
fi

# 5. 重新部署
deployed=0
if ! squirrel_running; then
  log "第 5 步：鼠须管进程没有运行，不部署。本脚本不会手动启动输入法。"
  log "  文件已就位，鼠须管下次启动时会自动部署。刚安装完时系统通常要注销后重新登录才会启动它，是否注销由你决定。"
else
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")
  [ "$pressure" = 1 ] || fail "内存压力等级变为 ${pressure}，不部署"
  before=0
  [ ! -f "$rime_log" ] || before=$(wc -l <"$rime_log")
  "$squirrel" --reload >>"$log_file" 2>&1 || fail "--reload 失败（见日志）"
  log "已通知鼠须管重新部署，等待结果"
  i=0
  result=""
  while [ "$i" -lt "$deploy_timeout" ]; do
    if [ -f "$rime_log" ]; then
      result=$(tail -n +"$((before + 1))" "$rime_log" | sed -n 's/.*tasks ran: //p' | tail -n 1)
      [ -z "$result" ] || break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -z "$result" ]; then
    # 部署可能还在进行，这时恢复文件会和它冲突，所以只停止并报告，不自动回滚
    log "停止：${deploy_timeout} 秒内没有看到部署结果。没有自动回滚（部署可能仍在进行）。"
    log "  请看鼠须管日志 ${rime_log}；如需回滚：mv \"$rime_dir\" \"$rime_dir.failed-$stamp\" && ditto \"$backup_dir/Rime\" \"$rime_dir\"，然后在鼠须管菜单里选「重新部署」"
    exit 1
  fi
  case "$result" in
    *" 0 failure"*) ;;
    *) fail "部署有失败：${result}（见 ${rime_log}）" ;;
  esac
  deployed=1
  log "第 5 步完成：部署结果 $result"
fi

# 6. 验证
if [ "$deployed" = 1 ]; then
  squirrel_running || fail "部署后鼠须管进程不在运行"
  [ -f "$rime_dir/build/$schema.schema.yaml" ] || fail "没有找到部署出的 build/$schema.schema.yaml"
fi
source_enabled || fail "鼠须管不在系统输入法列表里"
log "第 6 步完成：验证通过"
log "安装完成。备份在 ${backup_dir}，日志在 $log_file"
echo
echo "请在菜单栏选择鼠须管，确认打 ${test_hint}。"
