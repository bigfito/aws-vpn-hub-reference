
#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Instala en un equipo Windows (workstation-2) el perfil de vpn-hub para el
    servicio de OpenVPN, DETENIDO y en inicio Manual (aún no la enciendes), y, si el
    paquete lo incluye, el actualizador de DNS como tarea programada.

.DESCRIPTION
    Tú enciendes la VPN cuando necesites el túnel con "vpn-hub-service.cmd on" y la apagas al
    regresar con "vpn-hub-service.cmd off". Para que esos comandos funcionen sin
    administrador, este script da a tu usuario permiso de iniciar, detener y
    configurar el servicio OpenVPNService. Como ese servicio corre como SYSTEM,
    ese permiso equivale en la práctica a administrador (ver el comentario del
    paso 2); el permiso original queda respaldado en C:\ProgramData\vpn-hub\.

.EXAMPLE
    # Dentro del paquete que genera Terraform (terraform\hub\out\<equipo>\), PowerShell como administrador:
    powershell -ExecutionPolicy Bypass -File .\Install-VpnHub.ps1

.EXAMPLE
    # Desde el repositorio, dando el permiso a otro usuario de Windows:
    .\scripts\windows\Install-VpnHub.ps1 -DeviceDir .\terraform\hub\out\workstation-2 -UserName otro.usuario

.NOTES
    Requisito: OpenVPN Community 2.6+ con el componente "OpenVPN Service"
    (winget install --id OpenVPNTechnologies.OpenVPN -e, o https://openvpn.net/community-downloads/).
    El actualizador de DNS necesita, además:
      - AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
      - aws_signing_helper.exe en C:\Program Files\vpn-hub\:
        https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html
#>
[CmdletBinding()]
param(
    # Carpeta del paquete; vacío = la carpeta de este script.
    [string]$DeviceDir,
    [string]$OpenVpnDir = "$env:ProgramFiles\OpenVPN",
    # Usuario de Windows que podrá ejecutar vpn-hub-service on/off sin administrador.
    [string]$UserName = $env:USERNAME
)

$ErrorActionPreference = 'Stop'
# No se usa $PSScriptRoot como default en param(): con [CmdletBinding()] y
# "powershell -File", Windows PowerShell 5.1 lo deja vacío ahí (en el cuerpo sí
# tiene valor).
if (-not $DeviceDir) { $DeviceDir = $PSScriptRoot }
$DeviceDir = (Resolve-Path $DeviceDir).Path
$dataDir = "$env:ProgramData\vpn-hub"
$binDir = "$env:ProgramFiles\vpn-hub"
$serviceName = 'OpenVPNService'

$profiles = @(Get-ChildItem -Path $DeviceDir -Filter '*.ovpn' -File)
if ($profiles.Count -ne 1) {
    throw "Se esperaba exactamente un perfil .ovpn en $DeviceDir (hay $($profiles.Count))."
}
$ovpnFile = $profiles[0].FullName

# Busca un archivo junto a este script o, si no está, en la carpeta del paquete.
function Find-PackageFile {
    param([string]$Name)
    $path = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path $path)) { $path = Join-Path $DeviceDir $Name }
    return $path
}

# --- 1. Perfil para el servicio de OpenVPN (detenido) ----------------------
Write-Output "==> [1/3] Perfil de $serviceName con $($profiles[0].Name)"
if (-not (Test-Path "$OpenVpnDir\bin\openvpn.exe")) {
    throw "No se encontró OpenVPN en $OpenVpnDir. Instala OpenVPN Community 2.6+ (ver LEEME.md)."
}
if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
    throw "Falta el servicio $serviceName. Reinstala OpenVPN con Customize > `"OpenVPN Service`"."
}

New-Item -ItemType Directory -Force -Path "$OpenVpnDir\config-auto" | Out-Null
Copy-Item -Force $ovpnFile "$OpenVpnDir\config-auto\vpn-hub.ovpn"

# El túnel queda apagado hasta que alguien ejecute vpn-hub-service.cmd on.
Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
Set-Service -Name $serviceName -StartupType Manual
Write-Output '    Instalado, detenido y en inicio Manual.'

# --- 2. vpn-hub-service y permiso limitado sobre el servicio ----------------
Write-Output "==> [2/3] vpn-hub-service y permiso sobre $serviceName para $UserName"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -Force (Find-PackageFile 'vpn-hub-service.ps1'), (Find-PackageFile 'vpn-hub-service.cmd') $binDir

# Se agrega a la lista de permisos (SDDL) del servicio una entrada para tu usuario:
#   CC = leer configuración, DC = cambiar configuración (tipo de inicio),
#   LC = consultar estado, SW = ver dependientes, RP = iniciar, WP = detener,
#   DT = pausar, LO = interrogar, CR = control de usuario, RC = leer permisos.
# OJO: OpenVPNService corre como SYSTEM. Con DC, un programa que corra con tu
# usuario podría cambiar qué ejecuta el servicio, así que en la práctica este
# permiso equivale a ser administrador del equipo. Es aceptable porque ya lo
# eres; el permiso original se respalda para poder restaurarlo (docs/client-setup.md).
$sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$currentSddl = ((& sc.exe sdshow $serviceName) | Where-Object { $_.Trim() }) -join ''
if ($LASTEXITCODE -ne 0 -or -not $currentSddl) { throw "No se pudo leer el SDDL de $serviceName." }
$sddlBackup = Join-Path $dataDir "$serviceName.sddl.bak"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
if (-not (Test-Path $sddlBackup) -and $currentSddl -notmatch [regex]::Escape(";;;$sid)")) {
    Set-Content -Path $sddlBackup -Value $currentSddl -Encoding ASCII   # permiso original, sin la entrada nueva
}
if ($currentSddl -match [regex]::Escape(";;;$sid)")) {
    Write-Output '    El permiso ya existía.'
} else {
    $ace = "(A;;CCDCLCSWRPWPDTLOCRRC;;;$sid)"
    # La entrada va en la parte D: (permisos), antes de la parte S: (auditoría) si existe.
    $newSddl = if ($currentSddl -match 'S:') { $currentSddl -replace 'S:', "${ace}S:" } else { $currentSddl + $ace }
    & sc.exe sdset $serviceName $newSddl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe sdset falló con código $LASTEXITCODE" }
    Write-Output '    Permiso agregado.'
}
Write-Output "    Úsalo con: & '$binDir\vpn-hub-service.cmd' on | off | status"

# --- 3. Actualizador de DNS (solo equipos de la LAN) --------------------------
Write-Output '==> [3/3] Actualizador de DNS'
$certs = @(Get-ChildItem -Path $DeviceDir -Filter '*.crt' -File)
$keys = @(Get-ChildItem -Path $DeviceDir -Filter '*.key' -File)
$hasDnsFiles = ($certs.Count -eq 1) -and ($keys.Count -eq 1) -and
    (Test-Path (Join-Path $DeviceDir 'aws-config')) -and (Test-Path (Join-Path $DeviceDir 'dns-updater.json'))
if (-not $hasDnsFiles) {
    Write-Output '    Este paquete no incluye el actualizador de DNS. Listo.'
    return
}

$missing = @()
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { $missing += 'AWS CLI v2 (aws.exe)' }
if (-not (Test-Path "$binDir\aws_signing_helper.exe")) { $missing += "$binDir\aws_signing_helper.exe" }
if ($missing.Count -gt 0) {
    Write-Output "    Omitido: faltan $($missing -join ', ')."
    Write-Output '    Instálalos (pasos en docs/client-setup.md, sección DNS updater tools) y vuelve a ejecutar este script.'
    return
}

# Solo SYSTEM (S-1-5-18) y Administradores (S-1-5-32-544) leen la carpeta;
# se usan SIDs porque el nombre del grupo cambia con el idioma de Windows.
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
Copy-Item -Force $certs[0].FullName, $keys[0].FullName $dataDir
Copy-Item -Force (Join-Path $DeviceDir 'aws-config') $dataDir
Copy-Item -Force (Join-Path $DeviceDir 'dns-updater.json') $dataDir
& icacls $dataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls falló con código $LASTEXITCODE" }

Copy-Item -Force (Find-PackageFile 'Update-VpnHubDns.ps1') $binDir

# Tarea programada como SYSTEM cada 2 minutos; sin VPN conectada no hace nada.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$binDir\Update-VpnHubDns.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 2)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'vpn-hub-dns' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "    Instalado. Registrará el nombre del equipo unos 2 minutos después de 'vpn-hub-service.cmd on'."
Write-Output '    Revisa con: Get-ScheduledTaskInfo -TaskName vpn-hub-dns'

