# ============================================================
# 运行全部.ps1 —— sys_oneshot 的统一入口
#
# 不带 -Apply / -Restore 时**只读**：只打印每个补丁当前状态，不动任何东西。
#
# 用法：
#   .\运行全部.ps1                  列出所有补丁 + 状态
#   .\运行全部.ps1 -Name 迅雷       只看匹配的补丁
#   .\运行全部.ps1 -Apply           应用所有「未生效」的（已生效的跳过）
#   .\运行全部.ps1 -Apply -Name 迅雷        只应用匹配的
#   .\运行全部.ps1 -Apply -Name 迅雷 -Force 已生效也强制重跑
#   .\运行全部.ps1 -Restore -Name 迅雷      卸载匹配的（-Restore 必须带 -Name）
#
# 判定「要不要跑」靠的是每个补丁自己的 -Detect（真实检查系统状态），
# 不是靠台账。台账只记录历史，防止人忘。
#
# 退出码：0=全部已生效  1=有未生效的  2=参数错误
# ============================================================
param(
    [string]$Name,
    [switch]$Apply,
    [switch]$Restore,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------
# 参数校验
# ---------------------------------------------------------------
if ($Restore -and -not $Name) {
    Write-Host '[错误] -Restore 必须同时指定 -Name' -ForegroundColor Red
    Write-Host '       批量卸载风险太大，只有明确点名才允许卸载。' -ForegroundColor DarkGray
    Write-Host '       例：.\运行全部.ps1 -Restore -Name 迅雷' -ForegroundColor DarkGray
    exit 2
}
if ($Apply -and $Restore) {
    Write-Host '[错误] -Apply 和 -Restore 不能同时给' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------
# 收集补丁（有 应用.ps1 的子目录才算）
# ---------------------------------------------------------------
$all = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '应用.ps1') } |
    Sort-Object Name)

if ($all.Count -eq 0) {
    Write-Host "库里还没有补丁（$root）" -ForegroundColor DarkGray
    exit 0
}

$targets = $all
if ($Name) {
    $targets = @($all | Where-Object { $_.Name -like "*$Name*" })
    if ($targets.Count -eq 0) {
        Write-Host "[错误] 没有名称匹配「$Name」的补丁。可选：" -ForegroundColor Red
        $all | ForEach-Object { Write-Host "       $($_.Name)" }
        exit 2
    }
    if ($targets.Count -gt 1) {
        Write-Host "[错误] 「$Name」匹配到 $($targets.Count) 个，请写得更具体：" -ForegroundColor Red
        $targets | ForEach-Object { Write-Host "       $($_.Name)" }
        exit 2
    }
}

# ---------------------------------------------------------------
# 需要写系统时要求管理员（只读模式不要求）
# ---------------------------------------------------------------
if (($Apply -or $Restore) -and -not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权…' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Name)    { $argList += @('-Name', "`"$Name`"") }
    if ($Apply)   { $argList += '-Apply' }
    if ($Restore) { $argList += '-Restore' }
    if ($Force)   { $argList += '-Force' }
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    exit 0
}

# ---------------------------------------------------------------
# 调补丁的 应用.ps1
# ---------------------------------------------------------------
function Invoke-Patch {
    param([string]$AppPath, [string[]]$ExtraArgs = @())
    $pArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$AppPath`"") + $ExtraArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $pArgs `
        -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

function Get-StateText([int]$code) {
    switch ($code) {
        0 { return @{ Text = '已生效'; Color = 'Green' } }
        1 { return @{ Text = '未生效'; Color = 'Yellow' } }
        2 { return @{ Text = '不适用'; Color = 'DarkGray' } }
        default { return @{ Text = "未知($code)"; Color = 'Red' } }
    }
}

# ---------------------------------------------------------------
# 只读模式：列表 + 状态
# ---------------------------------------------------------------
Write-Host ''
Write-Host '=== sys_oneshot 补丁状态 ===' -ForegroundColor Cyan
Write-Host ''

$rows = @()
foreach ($t in $targets) {
    $appPath = Join-Path $t.FullName '应用.ps1'
    $code = Invoke-Patch -AppPath $appPath -ExtraArgs @('-Detect')
    $rows += [pscustomobject]@{ Name = $t.Name; Code = $code }
}

foreach ($r in $rows) {
    $st = Get-StateText $r.Code
    Write-Host ('  {0,-42}' -f $r.Name) -NoNewline
    Write-Host $st.Text -ForegroundColor $st.Color
}

$pending = @($rows | Where-Object { $_.Code -eq 1 })
Write-Host ''

if (-not $Apply -and -not $Restore) {
    if ($pending.Count -eq 0) {
        Write-Host '全部已生效，没有需要跑的。' -ForegroundColor Green
        if (-not $NoPause) { Read-Host '按回车退出' }
        exit 0
    }
    Write-Host ("有 {0} 个未生效。要应用请加 -Apply：" -f $pending.Count) -ForegroundColor Yellow
    Write-Host '  .\运行全部.ps1 -Apply' -ForegroundColor DarkGray
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 1
}

# ---------------------------------------------------------------
# 应用 / 卸载
# ---------------------------------------------------------------
$logPath = Join-Path $root '已应用清单.md'
function Add-Log([string]$patchName, [string]$action, [string]$result) {
    if (-not (Test-Path -LiteralPath $logPath)) {
        $head = "# 已应用清单`r`n`r`n> 由 运行全部.ps1 自动追加。历史记录，不代表当前状态；`r`n> 当前状态请跑 ``.\运行全部.ps1``。`r`n`r`n| 时间 | 补丁 | 动作 | 结果 |`r`n|---|---|---|---|`r`n"
        [IO.File]::WriteAllText($logPath, $head, (New-Object Text.UTF8Encoding($false)))
    }
    $line = "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $patchName | $action | $result |`r`n"
    [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
}

$fail = 0
foreach ($r in $rows) {
    $patchPath = (Join-Path $root $r.Name)
    $appPath = Join-Path $patchPath '应用.ps1'

    if ($Restore) {
        Write-Host ''
        Write-Host "--- 卸载：$($r.Name) ---" -ForegroundColor Magenta
        $code = Invoke-Patch -AppPath $appPath -ExtraArgs @('-Restore', '-NoPause')
        if ($code -eq 0) {
            Write-Host '  卸载完成' -ForegroundColor Green
            Add-Log $r.Name '卸载' '成功'
        } else {
            Write-Host "  卸载失败（退出码 $code）" -ForegroundColor Red
            Add-Log $r.Name '卸载' "失败($code)"
            $fail++
        }
        continue
    }

    # Apply
    if ($r.Code -eq 2) {
        Write-Host "  跳过（不适用）：$($r.Name)" -ForegroundColor DarkGray
        continue
    }
    if ($r.Code -eq 0 -and -not $Force) {
        Write-Host "  跳过（已生效）：$($r.Name)" -ForegroundColor DarkGray
        continue
    }

    Write-Host ''
    Write-Host "--- 应用：$($r.Name) ---" -ForegroundColor Magenta
    $extra = @('-NoPause')
    if ($Force) { $extra += '-Force' }
    $code = Invoke-Patch -AppPath $appPath -ExtraArgs $extra
    if ($code -eq 0) {
        Write-Host '  应用完成' -ForegroundColor Green
        Add-Log $r.Name '应用' '成功'
    } else {
        Write-Host "  应用失败（退出码 $code）" -ForegroundColor Red
        Add-Log $r.Name '应用' "失败($code)"
        $fail++
    }
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "$fail 个补丁失败，请看上面的输出。" -ForegroundColor Red
} else {
    Write-Host '全部完成。' -ForegroundColor Green
}
Write-Host "台账：$logPath" -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '按回车退出' }
if ($fail -gt 0) { exit 1 }
exit 0
