# 安装到小狼毫（Weasel）用户目录并重新部署；没装小狼毫时先自动安装。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
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

# 不覆盖用户已有的 default.custom.yaml，避免丢掉其它方案
$customPath = Join-Path $rimeDir "default.custom.yaml"
$hadCustom = Test-Path $customPath

Copy-Item (Join-Path $root "data\*.yaml") $rimeDir -Force
Copy-Item (Join-Path $root "schema\lua\*.lua") (Join-Path $rimeDir "lua") -Force
Get-ChildItem (Join-Path $root "schema\*.yaml") | Where-Object {
  -not ($hadCustom -and $_.Name -eq "default.custom.yaml")
} | Copy-Item -Destination $rimeDir -Force
if ($hadCustom) {
  Write-Host "保留了你原有的 default.custom.yaml，请在 schema_list 中加入：- schema: wubi86_pinyin"
}

$deployer = Find-WeaselDeployer
if ($deployer) {
  & $deployer.FullName /deploy
  Write-Host "已安装并重新部署。"
} else {
  Write-Host "安装后仍未找到小狼毫，请到 https://rime.im/download/ 手动安装，然后在托盘菜单中选择「重新部署」。"
}
