
@echo off
rem Atajo para vpn-hub-service.ps1: vpn-hub-service.cmd on | off | status
rem Evita escribir la ruta completa de PowerShell y la política de ejecución.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn-hub-service.ps1" %*

