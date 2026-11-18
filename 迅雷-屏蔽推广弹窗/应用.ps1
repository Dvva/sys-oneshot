# ============================================================
# 应用.ps1 —— 屏蔽迅雷推广弹窗（会员付费弹窗 / 活动页）
#
# 用法（需管理员 PowerShell）：
#   .\应用.ps1              应用（已生效则跳过）
#   .\应用.ps1 -Detect      只检测，不修改任何东西
#   .\应用.ps1 -Restore     卸载 / 还原
#   .\应用.ps1 -Force       已生效也再跑一遍（本脚本本身幂等，通常无需）
#   .\应用.ps1 -WhatIfOnly  只看会做什么，不改任何东西
#   .\应用.ps1 -KeepRunning 不改 hosts 时不强杀迅雷（默认会先退出迅雷）
#
# 退出码（-Detect 时）：0=已生效  1=未生效  2=不适用（没装迅雷）
#
# 原理见同目录《原理说明.md》
# ============================================================
param(
    [switch]$Detect,
    [switch]$Restore,
    [switch]$Force,
    [switch]$WhatIfOnly,
    [switch]$KeepRunning,
    [switch]$NoPause      # 本脚本末尾不暂停，此参数只为统一入口调用时不报错
)

$ErrorActionPreference = 'Stop'
$script:changes = New-Object System.Collections.Generic.List[string]
$script:errors  = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$HOSTS = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HOSTS_MARKER = 'Thunder ad domains'

# 活动 / 推广域名（实测：这些域名只用于会员活动与推广，不影响下载）
$AD_DOMAINS = @(
    'act-youxi.xunlei.com'
    'act-vip-ssl.xunlei.com'
    'dy1-vip-ssl.xunlei.com'
    'dyactive2-vip-ssl.xunlei.com'
    'faileddy1-vip-ssl.xunlei.com'
    'video-vip-ssl.xunlei.com'
    'control-vip.xunlei.com'
    'dy1-report-vip.xunlei.com'
)

# 会员付费弹窗插件（本地 Electron 插件，hosts 拦不住）
$PLUGIN_NAME = 'VipPayCenter2025'
$PLUGIN_BACKUP_DIR = '_plugin_backup'

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "  $msg" }

function Find-ThunderRoot {
    # 先查注册表卸载项，再退回常见路径
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        $items = Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '迅雷|Thunder' -and $_.InstallLocation }
        foreach ($it in $items) {
            $p = $it.InstallLocation.TrimEnd('\')
            if (Test-Path (Join-Path $p 'Thunder')) { return (Join-Path $p 'Thunder') }
            if (Test-Path (Join-Path $p 'program')) { return $p }
        }
    }
    foreach ($p in @('D:\迅雷12\Thunder', 'C:\Program Files (x86)\Thunder Network\Thunder',
                     'C:\Program Files\Thunder Network\Thunder')) {
        if (Test-Path (Join-Path $p 'program')) { return $p }
    }
    return $null
}

function Stop-Thunder {
    $names = 'thunder', 'ThunderStart', 'xllite', 'ThunderCmd', 'XLBugReport'
    $running = $false
    foreach ($n in $names) {
        if (Get-Process $n -ErrorAction SilentlyContinue) { $running = $true }
    }
    if (-not $running) { return }
    Write-Step '正在关闭迅雷…'
    foreach ($n in $names) {
        Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 4
    foreach ($n in $names) {
        Get-Process $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Start-Thunder($root) {
    $exe = Join-Path $root 'program\ThunderStart.exe'
    if (Test-Path $exe) {
        Start-Process $exe -WorkingDirectory (Join-Path $root 'program')
        $script:changes.Add('已重新启动迅雷')
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# hosts
# ---------------------------------------------------------------------------
function Set-HostsBlock {
    if (-not (Test-Path $HOSTS)) {
        $script:errors.Add("找不到 hosts: $HOSTS")
        return
    }
    $content = Get-Content -LiteralPath $HOSTS -Raw
    if ($content -match [regex]::Escape($HOSTS_MARKER)) {
        Write-Step 'hosts 屏蔽块已存在，跳过'
        return
    }
    $bak = "$HOSTS.bak_$(Get-Date -Format yyyyMMdd_HHmmss)_thunder"
    Copy-Item -LiteralPath $HOSTS -Destination $bak -Force
    $script:changes.Add("已备份 hosts: $bak")

    $lines = @('', "# ==== $HOSTS_MARKER ($(Get-Date -Format yyyy-MM-dd)) ====")
    foreach ($d in $AD_DOMAINS) { $lines += "0.0.0.0 $d" }
    $lines += "# ==== end $HOSTS_MARKER ===="

    if ($WhatIfOnly) {
        Write-Step ('将写入 ' + $AD_DOMAINS.Count + ' 条 hosts 屏蔽')
        return
    }
    Add-Content -LiteralPath $HOSTS -Value $lines -Encoding ascii
    $script:changes.Add("已写入 $($AD_DOMAINS.Count) 条 hosts 屏蔽")
}

function Remove-HostsBlock {
    if (-not (Test-Path $HOSTS)) { return }
    $content = Get-Content -LiteralPath $HOSTS -Raw
    if ($content -notmatch [regex]::Escape($HOSTS_MARKER)) {
        Write-Step 'hosts 里没有屏蔽块，跳过'
        return
    }
    if ($WhatIfOnly) { Write-Step '将移除 hosts 屏蔽块'; return }

    $bak = "$HOSTS.bak_$(Get-Date -Format yyyyMMdd_HHmmss)_restore"
    Copy-Item -LiteralPath $HOSTS -Destination $bak -Force
    $new = [regex]::Replace(
        $content,
        "(?ms)^\s*# ==== $([regex]::Escape($HOSTS_MARKER)).*?^# ==== end $([regex]::Escape($HOSTS_MARKER)) ====\r?\n?",
        '')
    [IO.File]::WriteAllText($HOSTS, $new, [Text.UTF8Encoding]::new($false))
    $script:changes.Add('已移除 hosts 屏蔽块')
}

# ---------------------------------------------------------------------------
# 插件（会员付费弹窗）
# ---------------------------------------------------------------------------
function Get-PluginPaths($root) {
    $pluginsDir = Join-Path $root 'program\resources\app\plugins'
    return @{
        Dir     = $pluginsDir
        Target  = Join-Path $pluginsDir $PLUGIN_NAME
        Renamed = Join-Path $pluginsDir "$PLUGIN_NAME.off"
        Backup  = Join-Path $root "$PLUGIN_BACKUP_DIR\$PLUGIN_NAME"
    }
}

function Disable-VipPlugin($root) {
    $p = Get-PluginPaths $root
    if (Test-Path $p.Renamed) {
        Write-Step "插件已是禁用状态（$PLUGIN_NAME.off）"
        return
    }
    if (-not (Test-Path $p.Target)) {
        Write-Step "未找到 $PLUGIN_NAME 插件目录（可能已被删除或版本变了）"
        return
    }
    if ($WhatIfOnly) { Write-Step "将把 $PLUGIN_NAME 改名为 $PLUGIN_NAME.off"; return }

    # 先备份到 plugins 之外，避免被当插件扫描
    if (-not (Test-Path $p.Backup)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $p.Backup) | Out-Null
        Copy-Item -LiteralPath $p.Target -Destination $p.Backup -Recurse -Force
        $script:changes.Add("已备份插件: $($p.Backup)")
    }
    Rename-Item -LiteralPath $p.Target -NewName "$PLUGIN_NAME.off" -Force
    $script:changes.Add("已禁用插件: $PLUGIN_NAME → $PLUGIN_NAME.off")
}

function Enable-VipPlugin($root) {
    $p = Get-PluginPaths $root
    if (Test-Path $p.Target) { Write-Step '插件已是启用状态'; return }
    if (-not (Test-Path $p.Renamed)) {
        Write-Step "找不到 $PLUGIN_NAME.off，无法还原"
        return
    }
    if ($WhatIfOnly) { Write-Step "将把 $PLUGIN_NAME.off 改回 $PLUGIN_NAME"; return }
    Rename-Item -LiteralPath $p.Renamed -NewName $PLUGIN_NAME -Force
    $script:changes.Add("已恢复插件: $PLUGIN_NAME")
}

# ---------------------------------------------------------------------------
# 迅雷本地配置
# ---------------------------------------------------------------------------
function Set-ThunderConfig($root, [bool]$block) {
    $cfg = Join-Path $root 'Profiles\config.json'
    if (-not (Test-Path $cfg)) {
        $script:errors.Add("找不到 $cfg")
        return
    }
    try {
        $json = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $script:errors.Add("config.json 解析失败: $($_.Exception.Message)")
        return
    }

    $wantBubble = -not $block
    $wantTeam   = -not $block
    $changed = @()

    if ($json.PSObject.Properties.Name -contains 'GUIDE_INFO' -and
        $json.GUIDE_INFO.isShowBubble -ne $wantBubble) {
        $json.GUIDE_INFO.isShowBubble = $wantBubble
        $changed += "GUIDE_INFO.isShowBubble=$wantBubble"
    }
    if ($json.PSObject.Properties.Name -contains 'VipDownload' -and
        $json.VipDownload.TeamEnteranceSwitch -ne $wantTeam) {
        $json.VipDownload.TeamEnteranceSwitch = $wantTeam
        $changed += "VipDownload.TeamEnteranceSwitch=$wantTeam"
    }

    if ($changed.Count -eq 0) {
        Write-Step '迅雷配置无需修改'
        return
    }
    if ($WhatIfOnly) {
        Write-Step ('将修改: ' + ($changed -join ', '))
        return
    }
    $bak = "$cfg.bak_$(Get-Date -Format yyyyMMdd_HHmmss)_popup"
    Copy-Item -LiteralPath $cfg -Destination $bak -Force
    $jsonText = $json | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($cfg, $jsonText, [Text.UTF8Encoding]::new($false))
    $script:changes.Add('迅雷配置: ' + ($changed -join ', '))
}

# ---------------------------------------------------------------------------
# 状态检测（-Detect 专用，只读）
# ---------------------------------------------------------------------------
function Test-Applied($root) {
    # 1) hosts 屏蔽块
    if (-not (Test-Path $HOSTS)) { return $false }
    $content = Get-Content -LiteralPath $HOSTS -Raw -ErrorAction SilentlyContinue
    if ($content -notmatch [regex]::Escape($HOSTS_MARKER)) { return $false }

    # 2) 付费弹窗插件：要么已禁用（.off），要么该版本本来就没有
    $p = Get-PluginPaths $root
    if ((Test-Path $p.Target) -and -not (Test-Path $p.Renamed)) { return $false }

    # 3) 迅雷配置里的两个开关
    $cfg = Join-Path $root 'Profiles\config.json'
    if (Test-Path $cfg) {
        try {
            $json = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties.Name -contains 'GUIDE_INFO' -and
                $json.GUIDE_INFO.isShowBubble -eq $true) { return $false }
            if ($json.PSObject.Properties.Name -contains 'VipDownload' -and
                $json.VipDownload.TeamEnteranceSwitch -eq $true) { return $false }
        } catch { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# -Detect：只读，什么都不改
# ---------------------------------------------------------------------------
if ($Detect) {
    $detectRoot = Find-ThunderRoot
    if (-not $detectRoot) { exit 2 }          # 没装迅雷，不适用
    if (Test-Applied $detectRoot) { exit 0 }  # 已生效
    exit 1                                     # 未生效
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 迅雷推广弹窗屏蔽 ===' -ForegroundColor Cyan

if (-not (Test-Admin) -and -not $WhatIfOnly) {
    Write-Host '[错误] 修改 hosts 需要管理员权限。请右键「以管理员身份运行」。' -ForegroundColor Red
    exit 1
}

$root = Find-ThunderRoot
if (-not $root) {
    Write-Host '[错误] 找不到迅雷安装目录' -ForegroundColor Red
    exit 1
}
Write-Host "  迅雷目录: $root"

# 非 -Force 时先看是否已生效，已生效就不重复动
if (-not $Restore -and -not $WhatIfOnly -and -not $Force) {
    if (Test-Applied $root) {
        Write-Host '  已生效，跳过（如需强制重做加 -Force）' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
}

if ($WhatIfOnly) {
    Write-Host ''
    Write-Host '--- 预演（不会改动任何东西） ---' -ForegroundColor Yellow
} elseif (-not $KeepRunning) {
    Stop-Thunder
}

if ($Restore) {
    Remove-HostsBlock
    Enable-VipPlugin $root
    Set-ThunderConfig $root $false
} else {
    Set-HostsBlock
    Disable-VipPlugin $root
    Set-ThunderConfig $root $true
}

if (-not $WhatIfOnly) {
    ipconfig /flushdns | Out-Null
    $script:changes.Add('已刷新 DNS 缓存')
    if (-not $KeepRunning) { Start-Thunder $root }
}

Write-Host ''
if ($script:changes.Count -gt 0) {
    Write-Host '--- 已执行 ---' -ForegroundColor Green
    $script:changes | ForEach-Object { Write-Host "  [OK] $_" }
} else {
    Write-Host '  没有需要改动的地方。' -ForegroundColor DarkGray
}
if ($script:errors.Count -gt 0) {
    Write-Host '--- 警告 ---' -ForegroundColor Yellow
    $script:errors | ForEach-Object { Write-Host "  [!] $_" }
}

Write-Host ''
Write-Host '还原: .\卸载.cmd' -ForegroundColor DarkGray
Write-Host ''
