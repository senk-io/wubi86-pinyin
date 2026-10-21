#!/usr/bin/env sh
# 安装项目术语补全所需的常驻进程 wubi86d，以及它依赖的 Ollama 和模型，并设为登录后自动运行。
# 前提：已用 install-macos.sh 装好鼠须管和本方案。
#
# 用法：sh scripts/install-helper-macos.sh
# 环境变量：
#   WUBI86D_CHAT_MODEL   对话模型，默认 qwen2.5:7b
#   WUBI86D_EMBED_MODEL  向量模型，默认 bge-m3
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rime_dir="$HOME/Library/Rime"
data_dir="$rime_dir/wubi86d"
bin="$data_dir/bin/wubi86d"
label="io.senk.wubi86d"
plist="$HOME/Library/LaunchAgents/${label}.plist"
chat_model=${WUBI86D_CHAT_MODEL:-qwen2.5:7b}
embed_model=${WUBI86D_EMBED_MODEL:-bge-m3}
releases="https://github.com/senk-io/wubi86-pinyin/releases"

# 1. Ollama：没有就用 Homebrew 安装并设为后台服务
if ! command -v ollama >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "没有找到 Ollama 和 Homebrew。请先安装 Homebrew（https://brew.sh）或 Ollama（https://ollama.com/download）。" >&2
    exit 1
  fi
  echo "正在安装 Ollama ..."
  brew install ollama
fi
if ! curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1 && brew list ollama >/dev/null 2>&1; then
    brew services start ollama
  else
    open -g -a Ollama 2>/dev/null || (ollama serve >/dev/null 2>&1 &)
  fi
  i=0
  until curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      echo "Ollama 没有启动成功，请手动运行 ollama serve 后重试。" >&2
      exit 1
    fi
    sleep 1
  done
fi

# 2. 模型：缺哪个拉哪个
for model in "$chat_model" "$embed_model"; do
  if ! ollama list | awk 'NR > 1 {print $1}' | grep -qx "${model}\(:latest\)\{0,1\}"; then
    echo "正在下载模型 ${model}（首次需要几分钟）..."
    ollama pull "$model"
  fi
done

# 3. wubi86d：本机有 Go 就从源码编译，否则下载发布版
mkdir -p "$data_dir/bin"
if command -v go >/dev/null 2>&1; then
  echo "正在编译 wubi86d ..."
  (cd "$root/helper" && go build -trimpath -o "$bin" .)
else
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    *) arch=amd64 ;;
  esac
  asset="wubi86d-darwin-${arch}"
  echo "正在下载 wubi86d ..."
  curl -fL --progress-bar -o "$bin.download" "$releases/latest/download/${asset}"
  sums=$(curl -fsSL "$releases/latest/download/SHA256SUMS")
  expected=$(printf '%s\n' "$sums" | awk -v f="$asset" '$2 == f {print $1}')
  actual=$(shasum -a 256 "$bin.download" | awk '{print $1}')
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    rm -f "$bin.download"
    echo "wubi86d 校验失败，已停止。" >&2
    exit 1
  fi
  mv "$bin.download" "$bin"
  chmod +x "$bin"
fi

# 4. 配置：第一次运行会生成默认配置，再写入所选模型
if [ ! -f "$data_dir/config.json" ]; then
  "$bin" folders >/dev/null
  tmp="$data_dir/config.json.tmp"
  sed -e "s#\"chat_model\": \"[^\"]*\"#\"chat_model\": \"${chat_model}\"#" \
      -e "s#\"embed_model\": \"[^\"]*\"#\"embed_model\": \"${embed_model}\"#" \
      "$data_dir/config.json" > "$tmp" && mv "$tmp" "$data_dir/config.json"
fi

# 5. 登录后自动运行（launchd），崩溃自动重启
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>${bin}</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${data_dir}/wubi86d.log</string>
  <key>StandardErrorPath</key><string>${data_dir}/wubi86d.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
# bootout 不等旧进程退出就返回，马上 bootstrap 会报 5: Input/output error；最多等 5 秒
i=0
while launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$plist"

# 6. 让输入法重新部署，识别到 wubi86d 目录
squirrel="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
[ -x "$squirrel" ] && "$squirrel" --reload

# 这里不调用模型（不跑 try），以免安装一次就把模型载入内存
echo "wubi86d 已安装并在后台运行。当前的资料文件夹："
"$bin" folders || true
echo
echo "项目资料文件夹：编辑 ${data_dir}/config.json 的 folders，例如"
echo '  "folders": [{"name": "星辰", "path": "~/work/星辰/docs"}]'
echo "然后运行 launchctl kickstart -k gui/$(id -u)/${label} 让它重新读取配置。"
echo "打字时按 Control+Shift+R 轮换项目；wubi86d terms 查看当前项目抽出的术语。"
