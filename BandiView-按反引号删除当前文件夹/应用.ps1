# ============================================================
# 应用.ps1 —— BandiView 按 ` 键删除当前图片所在文件夹
#
# 作用：把本目录的「主脚本.ps1」+「启动器.exe」装到 %APPDATA%\BandiViewTools，
#       并把 BandiView 的外部编辑器改成这个启动器（按 ` 键即触发）。
#
# 用法：
#   .\应用.ps1              应用（已生效则跳过）
#   .\应用.ps1 -Detect      只检测，不修改任何东西
#   .\应用.ps1 -Restore     卸载（先备份注册表到 _备份\）
#   .\应用.ps1 -Force       已生效也强制重装
#
# 退出码（-Detect 时）：0=已生效  1=未生效  2=不适用
#
# 配置：同目录的「配置.toml」可改触发键（按键码）和注册表槽位（槽位），改完重跑本脚本生效。
# ============================================================
param(
    [switch]$Detect,
    [switch]$Restore,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:APPDATA 'BandiViewTools'
$reg  = 'HKCU:\Software\BandiView'
$keyCode   = 'c0'     # ` 键（VK_OEM_3），可被 配置.toml 覆盖
$slot      = 34       # userKeys 槽位，可被 配置.toml 覆盖
$exeName    = '启动器.exe'
$scriptName = '主脚本.ps1'

# ---------- 读同目录的 配置.toml（没有就用上面的默认值） ----------
$cfgPath = Join-Path $src '配置.toml'
if (Test-Path -LiteralPath $cfgPath) {
    foreach ($line in (Get-Content -LiteralPath $cfgPath -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith('[')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        switch ($k) {
            '按键码' {
                if ($v -match '^[0-9a-fA-F]{2}$') { $keyCode = $v.ToLower() }
                else { Write-Host "  [!] 配置.toml 的 按键码 不是两位十六进制，已忽略: $v" -ForegroundColor Yellow }
            }
            '槽位' {
                $n = 0
                if ([int]::TryParse($v, [ref]$n) -and $n -ge 0 -and $n -le 35) { $slot = $n }
                else { Write-Host "  [!] 配置.toml 的 槽位 必须是 0-35 的整数，已忽略: $v" -ForegroundColor Yellow }
            }
        }
    }
}

$destExe    = Join-Path $dest $exeName
$destSlot   = "userKeys.$slot"
$slotValue  = "CMD_LAUNCH_EDITOR|$keyCode|1"

function Test-Applied {
    if (-not (Test-Path -LiteralPath (Join-Path $dest $exeName)))   { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $dest $scriptName))) { return $false }
    if (-not (Test-Path -LiteralPath $reg)) { return $false }
    $p = Get-ItemProperty -LiteralPath $reg -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($p.extProg0 -ne $destExe) { return $false }
    if ($p.$destSlot -ne $slotValue) { return $false }
    return $true
}

# ---------------- 只检测 ----------------
if ($Detect) {
    if (Test-Applied) { exit 0 } else { exit 1 }
}

# ---------------- 卸载 ----------------
if ($Restore) {
    Write-Host '=== 卸载：BandiView 按 ` 删除当前文件夹 ===' -ForegroundColor Cyan

    # 先把注册表整棵导出备份，出问题可双击 .reg 还原
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bkDir  = Join-Path $src "_备份\$stamp"
    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    if (Test-Path -LiteralPath $reg) {
        $regBak = Join-Path $bkDir '注册表-BandiView.reg'
        & reg.exe export 'HKCU\Software\BandiView' "$regBak" /y | Out-Null
        if (Test-Path -LiteralPath $regBak) {
            Write-Host "  [备份] 注册表已导出: $regBak" -ForegroundColor Green
        } else {
            Write-Host '  [!] 注册表备份失败，已中止卸载' -ForegroundColor Red
            if (-not $NoPause) { Read-Host '按回车退出' }
            exit 1
        }
    } else {
        Write-Host '  [备份] 注册表项不存在，无需备份'
    }

    if (Test-Path -LiteralPath $reg) {
        Remove-ItemProperty -LiteralPath $reg -Name $destSlot -ErrorAction SilentlyContinue
        $p = Get-ItemProperty -LiteralPath $reg -ErrorAction SilentlyContinue
        if ($p.extProg0 -and $p.extProg0 -like '*BandiViewTools*') {
            Set-ItemProperty -LiteralPath $reg -Name 'extProg0' -Value 'mspaint.exe' -Type String
            Write-Host '  [OK] 外部编辑器已恢复为 mspaint.exe'
        } elseif ($p.extProg0) {
            Remove-ItemProperty -LiteralPath $reg -Name 'extProg0' -ErrorAction SilentlyContinue
            Write-Host '  [OK] 外部编辑器设置已移除'
        }
    }

    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] 已删除目录: $dest"
    }

    Write-Host ''
    Write-Host '卸载完成。请重启 BandiView 生效。' -ForegroundColor Green
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 0
}

# ---------------- 应用 ----------------
Write-Host '=== 应用：BandiView 按 ` 删除当前文件夹 ===' -ForegroundColor Cyan

if ((Test-Applied) -and -not $Force) {
    Write-Host '  已生效，跳过（如需强制重装加 -Force）' -ForegroundColor DarkGray
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 0
}

if (-not (Test-Path -LiteralPath (Join-Path $src $scriptName))) {
    Write-Host "  [错误] 本目录缺少 $scriptName，无法安装" -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $src $exeName))) {
    Write-Host "  [错误] 本目录缺少 $exeName，无法安装" -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 1
}

# 0. 清理旧版本（改名前）留下的文件名，避免新旧混装
foreach ($old in @('bv_delete_folder.ps1', 'bv_delete_launcher.exe', 'bv_delete_launcher.cs')) {
    $oldPath = Join-Path $dest $old
    if (Test-Path -LiteralPath $oldPath) {
        Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        Write-Host "  [清理] 旧文件: $old"
    }
}

# 1. 复制文件
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $src $scriptName) -Destination $dest -Force
Copy-Item -LiteralPath (Join-Path $src $exeName)    -Destination $dest -Force

# 2. 确保 ps1 带 UTF-8 BOM（Windows PowerShell 5.1 读中文需要）
$ps1Dest = Join-Path $dest $scriptName
$text = [IO.File]::ReadAllText($ps1Dest, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($ps1Dest, $text, (New-Object Text.UTF8Encoding($true)))
Write-Host "  [1/2] 文件已装到: $dest"

# 3. 写注册表
if (-not (Test-Path -LiteralPath $reg)) { New-Item -Path $reg -Force | Out-Null }
Set-ItemProperty -LiteralPath $reg -Name 'extProg0' -Value $destExe -Type String
Set-ItemProperty -LiteralPath $reg -Name $destSlot  -Value $slotValue -Type String

$count = (Get-ItemProperty -LiteralPath $reg -Name 'userKeys.count' -ErrorAction SilentlyContinue).'userKeys.count'
if (-not $count -or $count -le $slot) {
    Set-ItemProperty -LiteralPath $reg -Name 'userKeys.count' -Value ($slot + 1) -Type DWord
}
Write-Host '  [2/2] 注册表已配置:'
Write-Host "        extProg0    = $destExe"
Write-Host "        $destSlot  = $slotValue"

Write-Host ''
Write-Host '完成！在 BandiView 里按 ` 键：确认框（默认「是」）→ 文件夹进回收站，并自动切下一个文件夹。' -ForegroundColor Green
Write-Host '提示：BandiView 正在运行的话重启一次，让它重新读取设置。' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '按回车退出' }
exit 0
