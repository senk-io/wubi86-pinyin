# 安装到小狼毫（Weasel）用户目录并重新部署。
# 用法：powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
$ErrorActionPreference = "Stop"
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

$deployer = Get-ChildItem "$env:ProgramFiles\Rime\weasel-*\WeaselDeployer.exe", "${env:ProgramFiles(x86)}\Rime\weasel-*\WeaselDeployer.exe" -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if ($deployer) {
  & $deployer.FullName /deploy
  Write-Host "已安装并重新部署。"
} else {
  Write-Host "未找到小狼毫，请先安装：https://rime.im/download/ ，然后在托盘菜单中选择「重新部署」。"
}
