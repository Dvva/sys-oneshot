# ============================================================
# bv_delete_folder.ps1
# 由 BandiView「运行外部编辑器」调用，参数为当前图片的完整路径。
# 功能：
#   1. 弹一次确认框（默认「是」，回车即确认）
#   2. 先把 BandiView 切到 上一个/下一个 文件夹（避免删除后报错）
#   3. 把原文件夹（含图片）静默移到回收站
# 用法：powershell -File bv_delete_folder.ps1 "<图片路径>"
# 可选环境变量：
#   BV_NO_CONFIRM=1        跳过确认框
#   BV_NAV_DIR=next|prev|none   删除后切换方向（默认 next）
# ============================================================
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ImagePath
)

$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'bv_delete.log'
$imageExt = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.avif', '.jxl',
              '.tif', '.tiff', '.heic', '.jfif', '.ico', '.psd', '.svg', '.svgz')

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line -Encoding UTF8
}

# 找到相邻文件夹里的第一张图片（用于切换视图）
function Get-NeighborImage([string]$folder, [string]$direction) {
    $parent = [System.IO.Path]::GetDirectoryName($folder)
    if (-not $parent -or $direction -eq 'none') { return $null }

    $dirs = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name)
    if ($dirs.Count -lt 2) { return $null }

    $full = @($dirs | ForEach-Object { $_.FullName })
    $idx = [Array]::IndexOf($full, $folder)
    if ($idx -lt 0) { return $null }

    $order = @()
    if ($direction -eq 'prev') {
        for ($i = $idx - 1; $i -ge 0; $i--) { $order += $i }
        for ($i = $full.Count - 1; $i -gt $idx; $i--) { $order += $i }
    }
    else {
        for ($i = $idx + 1; $i -lt $full.Count; $i++) { $order += $i }
        for ($i = 0; $i -lt $idx; $i++) { $order += $i }
    }

    foreach ($i in $order) {
        $first = Get-ChildItem -LiteralPath $full[$i] -File -ErrorAction SilentlyContinue |
                 Where-Object { $imageExt -contains $_.Extension.ToLower() } |
                 Sort-Object Name | Select-Object -First 1
        if ($first) { return $first.FullName }
    }
    return $null
}

try {
    # ---------- 校验 ----------
    if (-not (Test-Path -LiteralPath $ImagePath)) {
        Write-Log "跳过：路径不存在 $ImagePath"
        exit 1
    }

    $img = Get-Item -LiteralPath $ImagePath
    if ($img.PSIsContainer) {
        Write-Log "跳过：不是文件 $ImagePath"
        exit 1
    }

    $folder = $img.Directory.FullName
    $folderName = $img.Directory.Name

    # 安全护栏：不删盘符根目录、桌面/下载等顶层目录
    $root = [System.IO.Path]::GetPathRoot($folder)
    if ($folder.TrimEnd('\') -eq $root.TrimEnd('\')) {
        Write-Log "拒绝：目标是磁盘根目录 $folder"
        exit 1
    }
    $blocked = @('Desktop', 'Downloads', 'Documents', 'Pictures', 'Videos',
                 '桌面', '下载', '文档', '图片', '视频')
    if ($blocked -contains $folderName) {
        Write-Log "拒绝：受保护目录 $folder"
        exit 1
    }

    # ---------- 确认（只弹一次，默认「是」） ----------
    if ($env:BV_NO_CONFIRM -ne '1') {
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "确定要删除整个文件夹吗？`n`n$folder`n`n（移到回收站，可恢复）",
            "BandiView 删除文件夹",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log "取消：$folder"
            exit 0
        }
    }

    # ---------- 先切到相邻文件夹，避免删除后 BandiView 报错 ----------
    $direction = if ($env:BV_NAV_DIR) { $env:BV_NAV_DIR } else { 'next' }
    $neighbor = Get-NeighborImage $folder $direction
    if ($neighbor) {
        $exe = (Get-Process BandiView -ErrorAction SilentlyContinue | Select-Object -First 1).Path
        if (-not $exe) { $exe = 'D:\BandiView\BandiView.exe' }
        Start-Process -FilePath $exe -ArgumentList "`"$neighbor`""
        Start-Sleep -Milliseconds 1300
        Write-Log "已切换到：$neighbor"
    }
    else {
        Write-Log "没有相邻文件夹可切换：$folder"
    }

    # ---------- 删除到回收站（静默，最多重试 3 次） ----------
    if (-not ("ShFileOp" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ShFileOp
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    public static int Delete(string path)
    {
        var op = new SHFILEOPSTRUCT();
        op.wFunc = 3;              // FO_DELETE
        op.pFrom = path + "\0\0";  // 双重空字符结尾
        op.fFlags = 0x40 | 0x10 | 0x4 | 0x400;  // ALLOWUNDO|NOCONFIRMATION|SILENT|NOERRORUI
        return SHFileOperation(ref op);
    }
}
"@
    }

    $rc = -1
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $rc = [ShFileOp]::Delete($folder)
        Start-Sleep -Milliseconds 600
        if (-not (Test-Path -LiteralPath $folder)) { break }
    }

    if (Test-Path -LiteralPath $folder) {
        Write-Log "失败：重试 3 次仍存在（rc=$rc） $folder"
        exit 1
    }
    Write-Log "已删除到回收站：$folder"
    exit 0
}
catch {
    Write-Log "错误：$($_.Exception.Message)  路径=$ImagePath"
    exit 1
}
