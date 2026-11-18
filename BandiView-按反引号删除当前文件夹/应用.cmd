@echo off
rem BandiView 按 ` 删除当前文件夹 —— 应用
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0应用.ps1"
