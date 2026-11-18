# ============================================================
# 卸载.ps1 —— 等价于 运行「应用.ps1 -Restore」
# 保留这个文件是为了让每个补丁目录都有明确的双击入口
# ============================================================
$app = Join-Path $PSScriptRoot '应用.ps1'
if (-not (Test-Path -LiteralPath $app)) {
    Write-Host "找不到 应用.ps1，无法卸载" -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}
& $app -Restore
exit $LASTEXITCODE
