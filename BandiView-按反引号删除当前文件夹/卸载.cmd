@echo off
rem BandiView 按 ` 删除当前文件夹 —— 卸载
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0应用.ps1" -Restore
