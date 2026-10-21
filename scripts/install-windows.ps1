# 安装到小狼毫（Weasel）用户目录并重新部署；没装小狼毫时先自动安装。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 [wubi86-pinyin|pinyin]
#   安装包：wubi86-pinyin 为SENK五笔混拼输入法86版，pinyin 为SENK拼音输入法；不给出时读取根目录的 VARIANT 文件，
#   没有则为 wubi86-pinyin。文件清单与 scripts/assemble.sh 一致。
param([string]$Variant = "")
$ErrorActionPreference = "Stop"

function Find-WeaselDeployer {
  Get-ChildItem "$env:ProgramFiles\Rime\weasel-*\WeaselDeployer.exe", "${env:ProgramFiles(x86)}\Rime\weasel-*\WeaselDeployer.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
}

function Install-Weasel {
  # 从 GitHub 最新正式版中找安装包，静默安装（/S），会弹出一次管理员授权
  $release = Invoke-RestMethod "https://api.github.com/repos/rime/weasel/releases/latest" -Headers @{ "User-Agent" = "wubi86-pinyin" }
  $asset = $release.assets | Where-Object { $_.name -match '^weasel-.*-installer\.exe$' } | Select-Object -First 1
  if (-not $asset) { throw "没有在小狼毫 $($release.tag_name) 中找到安装包，请到 https://rime.im/download/ 手动安装。" }
  $installer = Join-Path $env:TEMP $asset.name
  Write-Host "正在下载小狼毫 $($release.tag_name) ..."
  Invoke-WebRequest $asset.browser_download_url -OutFile $installer -UseBasicParsing
  # 签名被篡改等异常直接停下；上游未签名的版本只给出提示（下载走 HTTPS，来源是官方 Release）
  $sig = Get-AuthenticodeSignature $installer
  if ($sig.Status -eq "NotSigned") {
    Write-Warning "该版本安装包没有代码签名，来源为官方 GitHub Release。"
  } elseif ($sig.Status -ne "Valid") {
    throw "小狼毫安装包签名校验失败（$($sig.Status)），已停止。"
  }
  Write-Host "正在安装小狼毫 ..."
  Start-Process $installer -ArgumentList "/S" -Verb RunAs -Wait
  Remove-Item $installer -ErrorAction SilentlyContinue
}

if (-not (Find-WeaselDeployer)) { Install-Weasel }
$root = Split-Path -Parent $PSScriptRoot
$rimeDir = Join-Path $env:APPDATA "Rime"
New-Item -ItemType Directory -Force -Path (Join-Path $rimeDir "lua") | Out-Null

if (-not $Variant) {
  $variantFile = Join-Path $root "VARIANT"
  $Variant = if (Test-Path $variantFile) { (Get-Content $variantFile -Raw).Trim() } else { "wubi86-pinyin" }
}
switch ($Variant) {
  "wubi86-pinyin" { $schema = "wubi86_pinyin"; $other = "senk_pinyin" }
  "pinyin" { $schema = "senk_pinyin"; $other = "wubi86_pinyin" }
  default { throw "未知的安装包：$Variant（可选 wubi86-pinyin、pinyin）" }
}

# 两个包共用：拼音词库
Copy-Item (Join-Path $root "data\pinyin_simp.*.yaml") $rimeDir -Force
Copy-Item (Join-Path $root "schema\$schema.schema.yaml") $rimeDir -Force
# 旧版本的本地模型接入已移除，删掉留下的脚本
foreach ($f in @("wubi_predict", "wubi_predict_switch", "pinyin_filter")) {
  Remove-Item (Join-Path $rimeDir "lua\$f.lua") -Force -ErrorAction SilentlyContinue
}
if ($Variant -eq "wubi86-pinyin") {
  Copy-Item (Join-Path $root "data\wubi86_jidian*.yaml") $rimeDir -Force
  foreach ($f in @("wubi_safe", "wubi_mixed_filter", "wubi_memory", "wubi_topup")) {
    Copy-Item (Join-Path $root "schema\lua\$f.lua") (Join-Path $rimeDir "lua") -Force
  }
}

# default.custom.yaml：本脚本生成的直接重新生成；用户自己的不覆盖，避免丢掉其它方案
$customPath = Join-Path $rimeDir "default.custom.yaml"
$ours = -not (Test-Path $customPath) -or ((Get-Content $customPath -TotalCount 1) -match "wubi86-pinyin")
if ($ours) {
  $lines = @("# 由 wubi86-pinyin 的安装脚本生成。已有其它方案的用户可以自行合并 schema_list", "patch:", "  schema_list:", "    - schema: $schema")
  if (Test-Path (Join-Path $rimeDir "$other.schema.yaml")) { $lines += "    - schema: $other" }
  $lines += "  menu/page_size: 6"
  [System.IO.File]::WriteAllLines($customPath, $lines, (New-Object System.Text.UTF8Encoding $false))
} elseif (-not (Select-String -Path $customPath -Pattern $schema -Quiet)) {
  Write-Host "保留了你原有的 default.custom.yaml，请在 schema_list 中加入：- schema: $schema"
}

$deployer = Find-WeaselDeployer
if ($deployer) {
  & $deployer.FullName /deploy
  Write-Host "已安装并重新部署。"
} else {
  Write-Host "安装后仍未找到小狼毫，请到 https://rime.im/download/ 手动安装，然后在托盘菜单中选择「重新部署」。"
}
