
#Requires -Version 5.1

<#
.SYNOPSIS
    Enciende o apaga la VPN de vpn-hub en este equipo (workstation-2).

.DESCRIPTION
      on      Pone OpenVPNService en inicio Automático y lo arranca. Si el equipo
              se reinicia mientras estás fuera (por ejemplo, por Windows Update),
              vuelve a conectar solo, sin que nadie inicie sesión.
      off     Detiene OpenVPNService y lo deja en inicio Manual.
      status  Muestra el estado sin cambiar nada.

    No necesita "Ejecutar como administrador": Install-VpnHub.ps1 da a tu
    usuario permiso de iniciar, detener y configurar OpenVPNService.

    Este script solo controla el equipo. La asociación del endpoint (lo que cobra
    AWS por hora) se enciende y apaga en la consola de AWS o con vpn-hub.sh; si está apagada, el
    servicio sigue reintentando y conecta solo unos minutos después de encenderla.

.EXAMPLE
    & 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' on

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\vpn-hub-service.ps1 off
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action,

    [string]$ServiceName = 'OpenVPNService',

    # Inicio de las IPs de túnel: client CIDR 10.81.0.0/22 = 10.81.0.x a 10.81.3.x.
    [string]$ClientCidrPrefix = '10.81.',

    # Bitácora del perfil vpn-hub del servicio de OpenVPN. Vacío = la carpeta de
    # logs que OpenVPN guarda en el registro (log_dir).
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
if ($Action -notin @('on', 'off', 'status')) {
    Write-Output "Uso: & 'C:\Program Files\vpn-hub\vpn-hub-service.cmd' on | off | status"
    exit 2
}

# OpenVPN 2.7 escribe en C:\ProgramData\OpenVPN\Log; versiones anteriores, en
# C:\Program Files\OpenVPN\log. La carpeta real está en HKLM:\SOFTWARE\OpenVPN.
if (-not $LogFile) {
    $logDir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenVPN' -Name log_dir -ErrorAction SilentlyContinue).log_dir
    if (-not $logDir) { $logDir = "$env:ProgramData\OpenVPN\Log" }
    $LogFile = Join-Path $logDir 'vpn-hub.log'
}

# IP de túnel (la que empieza con $Prefix), si la hay.
function Get-TunnelIp {
    param([string]$Prefix)
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress.StartsWith($Prefix) } |
        Select-Object -First 1 -ExpandProperty IPAddress
}

# Estado del servicio, tipo de inicio, IP de túnel y última línea de la bitácora.
function Show-Status {
    param([string]$Name, [string]$Prefix, [string]$Log)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "No existe el servicio $Name. Instala OpenVPN Community (ver LEEME.md)." }
    $startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'").StartMode
    $ip = Get-TunnelIp -Prefix $Prefix
    Write-Output "Servicio $Name"
    Write-Output "  Tipo de inicio: $startMode   (Auto = arranca con el equipo, Manual = no)"
    Write-Output "  Estado:         $($svc.Status)"
    Write-Output ("  IP de túnel:    " + $(if ($ip) { $ip } else { 'ninguna (sin conexión)' }))
    # Con persist-tun la IP puede quedarse aunque la conexión se haya caído:
    # la última línea de la bitácora dice si está conectado o reintentando.
    $last = Get-Content -Path $Log -Tail 1 -ErrorAction SilentlyContinue
    Write-Output ("  Última bitácora: " + $(if ($last) { $last } else { 'sin registros' }))
}

# sc.exe con manejo del código de salida. Se usa sc.exe porque pide al sistema
# solo los permisos que Install-VpnHub.ps1 le dio a tu usuario sobre el servicio.
# Códigos aceptados: 1056 = ya estaba iniciado, 1062 = ya estaba detenido.
function Invoke-Sc {
    param([string[]]$Arguments, [int[]]$OkCodes = @(0))
    $ErrorActionPreference = 'Continue'
    $output = & sc.exe @Arguments 2>&1
    if ($OkCodes -notcontains $LASTEXITCODE) {
        throw "sc.exe $($Arguments -join ' ') falló ($LASTEXITCODE): $(($output | Out-String).Trim()). ¿Ya ejecutaste Install-VpnHub.ps1 como administrador?"
    }
}

switch ($Action) {
    'on' {
        Invoke-Sc @('config', $ServiceName, 'start=', 'auto')
        Invoke-Sc @('start', $ServiceName) -OkCodes @(0, 1056)
        Write-Output 'Servicio encendido. Esperando el túnel (hasta 30 s)...'
        for ($i = 0; $i -lt 15 -and -not (Get-TunnelIp -Prefix $ClientCidrPrefix); $i++) {
            Start-Sleep -Seconds 2
        }
        $tunnelIp = Get-TunnelIp -Prefix $ClientCidrPrefix
        if ($tunnelIp) {
            Write-Output "Conectado: IP de túnel $tunnelIp."
        } else {
            Write-Output 'Aún sin túnel. Si la asociación está apagada, enciéndela (consola de AWS o vpn-hub.sh):'
            Write-Output 'el servicio reintenta solo y conecta unos minutos después.'
        }
        Show-Status -Name $ServiceName -Prefix $ClientCidrPrefix -Log $LogFile
    }
    'off' {
        Invoke-Sc @('stop', $ServiceName) -OkCodes @(0, 1062)
        Invoke-Sc @('config', $ServiceName, 'start=', 'demand')
        Write-Output 'Servicio detenido y en inicio Manual.'
        Write-Output 'Si ya ningún equipo usa la VPN, apaga la asociación (consola de AWS o vpn-hub.sh).'
        Show-Status -Name $ServiceName -Prefix $ClientCidrPrefix -Log $LogFile
    }
    'status' {
        Show-Status -Name $ServiceName -Prefix $ClientCidrPrefix -Log $LogFile
    }
}

