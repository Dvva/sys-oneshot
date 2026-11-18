# ============================================================
# 应用.ps1 —— 关闭 Edge 下载安全警告
#
# 作用：写 HKLM\SOFTWARE\Policies\Microsoft\Edge\ExemptFileTypeDownloadWarnings，
#       让 Edge 对 exe / reg / bat 等常见文件不再弹「不常下载，可能有危险」。
#
# 用法（需管理员）：
#   .\应用.ps1              应用（已生效则跳过）
#   .\应用.ps1 -Detect      只检测，不修改任何东西
#   .\应用.ps1 -Restore     卸载（先备份整棵策略键到 _备份\）
#   .\应用.ps1 -Force       已生效也强制重写
#
# 退出码（-Detect 时）：0=已生效  1=未生效  2=不适用
#
# 注：本目录的《原版注册表.reg》只是原始来源留档，脚本不依赖它。
# ============================================================
param(
    [switch]$Detect,
    [switch]$Restore,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExemptFileTypeDownloadWarnings'
$keyNative = 'HKLM\SOFTWARE\Policies\Microsoft\Edge\ExemptFileTypeDownloadWarnings'

# 原文件里用到的扩展名（编号保留原样，缺 5 是原文件就没有）
$map = [ordered]@{
    '1'  = 'exe'; '2'  = 'reg'; '3'  = 'bat'; '4'  = 'vbs'
    '6'  = 'msi'; '7'  = 'js';  '8'  = 'inf'; '9'  = 'cmd'
    '10' = 'dll'; '11' = 'sys'; '12' = 'url'; '13' = 'ocx'
    '14' = 'apk'; '15' = 'crx'; '16' = 'xml'; '17' = 'msc'
    '18' = 'mht'
}

function Get-ValueText([string]$ext) {
    return "{`"file_extension`": `"$ext`", `"domains`": [`"*`"]}"
}

function Test-Applied {
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    foreach ($id in $map.Keys) {
        $want = Get-ValueText $map[$id]
        $have = $p.$id
        if ($have -ne $want) { return $false }
    }
    return $true
}

# ---------------- 只检测 ----------------
if ($Detect) {
    if (Test-Applied) { exit 0 } else { exit 1 }
}

# ---------------- 卸载 ----------------
if ($Restore) {
    Write-Host '=== 卸载：关闭 Edge 下载安全警告 ===' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $key)) {
        Write-Host '  策略键不存在，已经是原始状态，无需卸载' -ForegroundColor DarkGray
        if (-not $NoPause) { Read-Host '按回车退出' }
        exit 0
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bkDir = Join-Path $src "_备份\$stamp"
    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    $regBak = Join-Path $bkDir 'Edge-下载警告策略.reg'
    & reg.exe export $keyNative "$regBak" /y | Out-Null
    if (-not (Test-Path -LiteralPath $regBak)) {
        Write-Host '  [!] 注册表备份失败，已中止卸载' -ForegroundColor Red
        if (-not $NoPause) { Read-Host '按回车退出' }
        exit 1
    }
    Write-Host "  [备份] 已导出: $regBak" -ForegroundColor Green

    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Host '  [OK] 策略键已删除，请重启 Edge 生效' -ForegroundColor Green
    Write-Host ''
    Write-Host '卸载完成。' -ForegroundColor Green
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 0
}

# ---------------- 应用 ----------------
Write-Host '=== 应用：关闭 Edge 下载安全警告 ===' -ForegroundColor Cyan

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '  [错误] 需要管理员权限。请右键「以管理员身份运行」。' -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 1
}

if ((Test-Applied) -and -not $Force) {
    Write-Host '  已生效，跳过（如需强制重写加 -Force）' -ForegroundColor DarkGray
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 0
}

# 已存在但内容不符时，先备份再覆盖
if ((Test-Path -LiteralPath $key) -and -not (Test-Applied)) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bkDir = Join-Path $src "_备份\$stamp"
    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    $regBak = Join-Path $bkDir 'Edge-下载警告策略-覆盖前.reg'
    & reg.exe export $keyNative "$regBak" /y | Out-Null
    if (Test-Path -LiteralPath $regBak) {
        Write-Host "  [备份] 覆盖前已导出: $regBak" -ForegroundColor Green
    }
}

if (-not (Test-Path -LiteralPath $key)) {
    New-Item -Path $key -Force | Out-Null
}
foreach ($id in $map.Keys) {
    Set-ItemProperty -LiteralPath $key -Name $id -Value (Get-ValueText $map[$id]) -Type String
}

Write-Host "  [OK] 已写入 $($map.Count) 个扩展名的豁免策略" -ForegroundColor Green
Write-Host ''
Write-Host '完成！重启 Edge 生效。' -ForegroundColor Green
Write-Host '提示：这是企业策略项，Edge 设置界面里会显示「由你的组织管理」。' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '按回车退出' }
exit 0
