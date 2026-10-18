@echo off
rem Anvil: sets this Windows up for Minecraft (Bedrock, the PC version).
rem It shows what it will do and asks first. "Set up Minecraft.cmd undo" puts the settings back.
if /i "%~1"=="undo" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil-minecraft-setup.ps1" -Undo
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0anvil-minecraft-setup.ps1"
)
