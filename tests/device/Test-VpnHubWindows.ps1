
#Requires -Version 5.1

<#
.SYNOPSIS
    ¿La VPN de workstation-2 (Windows 11) está bien instalada? (T5.4)

.DESCRIPTION
    Se ejecuta EN workstation-2, en una PowerShell normal (sin administrador).
    Sin administrador, el respaldo del permiso y la tarea vpn-hub-dns no se pueden
    leer: solo se informa. Ejecútalo como administrador para exigirlos.
    Solo lee: nunca enciende ni apaga el servicio (eso lo hace quien opera, con
    vpn-hub-service.cmd on|off, cuando haga falta). Detecta en qué estado está y revisa lo que toca:

      Siempre:   servicio OpenVPNService, perfil config-auto\vpn-hub.ovpn,
                 C:\Program Files\vpn-hub\vpn-hub-service.cmd, respaldo del
                 permiso original del servicio, permiso de tu usuario sobre
                 OpenVPNService y Escritorio remoto activado. La regla de
                 firewall "RDP desde vpn-hub" es opcional y solo se informa:
                 la regla de firewall solo para la VPN es opcional, porque la LAN local también puede usar RDP.
      Apagado:   OpenVPNService detenido y en inicio Manual, sin IP de túnel.
      Encendido: OpenVPNService corriendo y en inicio Automático, IP de túnel
                 10.81.x.x, DNS 10.80.0.2 en la interfaz del túnel, tarea
                 vpn-hub-dns sin errores, el nombre propio resuelve a la IP de
                 túnel y se alcanza a los pares por su nombre de la VPN (por
                 defecto workstation-1:22). Es un ensayo del camino de la tableta: en el
                 día a día los equipos de la LAN se comunican por la LAN.

.PARAMETER SinPares
    No prueba el alcance a los otros equipos (antes de instalar workstation-1).

.PARAMETER Par
    Pares a probar como nombre:puerto. El nombre corto se completa con
    .vpn.example.internal. Por defecto: workstation-1:22.

.PARAMETER Help
    Muestra esta ayuda (también: Get-Help .\Test-VpnHubWindows.ps1 -Full).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\device\Test-VpnHubWindows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\device\Test-VpnHubWindows.ps1 -SinPares

.NOTES
    Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
    algo falla. No usa AWS ni modifica nada.
#>
[CmdletBinding()]
param(
    [switch]$SinPares,
    [string[]]$Par = @('workstation-1:22'),
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

$serviceName = 'OpenVPNService'
$zone = 'vpn.example.internal'
$clientPrefix = '10.81.'
$vpcDns = '10.80.0.2'
$script:failures = 0
$script:checks = 0

function Write-Ok {
    param([string]$Message)
    $script:checks++
    Write-Output "✅ OK: $Message"
}

function Write-Fail {
    param([string]$Message)
    $script:checks++
    $script:failures++
    Write-Output "❌ FALLA: $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Output "ℹ️  $Message"
}

# ¿Se abre una conexión TCP a host:puerto en menos de 5 segundos?
function Test-TcpPort {
    param([string]$HostName, [int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000)) { return $false }
        $client.EndConnect($connect)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# --- Siempre --------------------------------------------------------------------
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Fail "no existe el servicio $serviceName. Instala OpenVPN Community con 'OpenVPN Service' (LEEME.md)"
    Write-Output "Resultado: FALLA — $script:failures de $script:checks verificación(es) con error."
    exit 1
}
Write-Ok "existe el servicio $serviceName"

$checksPaths = @(
    @{ Path = "$env:ProgramFiles\OpenVPN\config-auto\vpn-hub.ovpn"; Label = 'perfil config-auto\vpn-hub.ovpn' },
    @{ Path = "$env:ProgramFiles\vpn-hub\vpn-hub-service.cmd"; Label = 'comando C:\Program Files\vpn-hub\vpn-hub-service.cmd' },
    @{ Path = "$env:ProgramData\vpn-hub\OpenVPNService.sddl.bak"; Label = 'respaldo del permiso original de OpenVPNService' }
)
foreach ($item in $checksPaths) {
    try {
        $exists = Test-Path -LiteralPath $item.Path -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        # C:\ProgramData\vpn-hub solo la leen SYSTEM y Administradores (guarda la
        # llave del equipo): sin administrador no se puede comprobar.
        Write-Info "$($item.Label): carpeta protegida, se comprueba solo como administrador."
        continue
    }
    if ($exists) { Write-Ok $item.Label } else { Write-Fail "falta $($item.Label) (ejecuta Install-VpnHub.ps1 como administrador)" }
}

# Permiso de tu usuario sobre el servicio: su SID aparece en el descriptor.
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ErrorActionPreference = 'Continue'
$sddl = (& sc.exe sdshow $serviceName 2>&1 | Out-String).Trim()
$ErrorActionPreference = 'Stop'
if ($sddl -match [regex]::Escape($userSid)) {
    Write-Ok "tu usuario tiene permiso sobre $serviceName (vpn-hub-service sin administrador)"
} else {
    Write-Fail "tu usuario no aparece en el permiso de $serviceName (ejecuta Install-VpnHub.ps1 como administrador)"
}

# Escritorio remoto activado (0 = permitido).
$denyTs = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
if ($denyTs -eq 0) { Write-Ok 'Escritorio remoto activado' } else { Write-Fail 'Escritorio remoto desactivado (Configuración → Sistema → Escritorio remoto)' }

# Regla de firewall de RDP para la VPN: opcional. Este ejemplo no exige
# limitar RDP al rango de la VPN, porque la LAN local también puede usarlo.
# Antes de producción, limita el puerto 3389 a los CIDR de la VPN si la LAN
# no debe entrar. El alcance por la VPN lo prueban los pares. Leer los
# filtros del firewall puede pedir administrador, así que aquí solo se informa.
try {
    $rule = Get-NetFirewallRule -DisplayName 'RDP desde vpn-hub' -ErrorAction Stop | Select-Object -First 1
    Write-Info "regla opcional 'RDP desde vpn-hub' presente (activa: $($rule.Enabled))."
} catch {
    Write-Info "sin la regla opcional 'RDP desde vpn-hub' (o no se pudo leer sin administrador); el alcance por la VPN se prueba desde los pares."
}

# --- Estado del servicio -----------------------------------------------------------
$startMode = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'").StartMode
$tunnel = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress.StartsWith($clientPrefix) } | Select-Object -First 1

if ($service.Status -eq 'Stopped' -and $startMode -eq 'Manual') {
    Write-Info 'estado: APAGADO (vpn-hub-service off).'
    Write-Ok "$serviceName detenido y en inicio Manual"
    if (-not $tunnel) { Write-Ok 'sin IP de túnel' } else { Write-Fail "hay IP de túnel $($tunnel.IPAddress) con el servicio apagado" }
} elseif ($service.Status -eq 'Running' -and $startMode -eq 'Auto') {
    Write-Info 'estado: ENCENDIDO (vpn-hub-service on).'
    Write-Ok "$serviceName corriendo y en inicio Automático"
    if ($tunnel) {
        Write-Ok "IP de túnel $($tunnel.IPAddress) en '$($tunnel.InterfaceAlias)'"
        $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $tunnel.InterfaceIndex -AddressFamily IPv4).ServerAddresses
        if ($dnsServers -contains $vpcDns) { Write-Ok "DNS $vpcDns en la interfaz del túnel" } else { Write-Fail "la interfaz del túnel usa DNS '$($dnsServers -join ', ')' (debe incluir $vpcDns)" }
    } else {
        Write-Fail 'sin IP de túnel 10.81.x.x: ¿está encendida la asociación (consola o vpn-hub.sh)? (vpn-hub-service.cmd status)'
    }

    # La tarea corre como SYSTEM: Windows no la muestra a usuarios sin
    # administrador. En ese caso la prueba funcional es la de abajo (el nombre
    # propio resuelve a la IP de túnel); como administrador, la tarea es obligatoria.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $task = Get-ScheduledTask -TaskName 'vpn-hub-dns' -ErrorAction SilentlyContinue
    if (-not $task -and -not $isAdmin) {
        Write-Info 'la tarea vpn-hub-dns no se ve sin administrador; la comprueba la resolución del nombre propio (abajo).'
    } elseif (-not $task) {
        Write-Fail 'no existe la tarea vpn-hub-dns (vuelve a ejecutar Install-VpnHub.ps1 con AWS CLI y aws_signing_helper.exe)'
    } else {
        $taskInfo = $task | Get-ScheduledTaskInfo
        if ($task.State -ne 'Disabled' -and $taskInfo.LastTaskResult -eq 0) {
            Write-Ok "tarea vpn-hub-dns activa, última ejecución sin error ($($taskInfo.LastRunTime))"
        } else {
            Write-Fail "tarea vpn-hub-dns en estado $($task.State), último resultado $($taskInfo.LastTaskResult) (revisa C:\ProgramData\vpn-hub)"
        }
    }

    $ownName = "$($env:COMPUTERNAME.ToLower()).$zone"
    $resolved = Resolve-DnsName -Name $ownName -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if ($tunnel -and $resolved -and $resolved.IPAddress -eq $tunnel.IPAddress) {
        Write-Ok "$ownName resuelve a la IP de túnel ($($resolved.IPAddress))"
    } else {
        Write-Fail "$ownName resuelve a '$($resolved.IPAddress)' (debe ser la IP de túnel); el actualizador corre cada 2 min"
    }

    if ($SinPares) {
        Write-Info 'se omite el alcance a los pares (-SinPares).'
    } else {
        foreach ($peer in $Par) {
            $peerHost, $peerPort = $peer -split ':', 2
            if ($peerHost -notmatch '\.') { $peerHost = "$peerHost.$zone" }
            if (Test-TcpPort -HostName $peerHost -Port ([int]$peerPort)) {
                Write-Ok "alcance a ${peerHost}:$peerPort"
            } else {
                Write-Fail "no se alcanza ${peerHost}:$peerPort (¿el par está encendido y su firewall lo permite?)"
            }
        }
    }
} else {
    Write-Fail "estado mixto: $serviceName está $($service.Status) con inicio $startMode. Ejecuta vpn-hub-service.cmd off (u on) para dejarlo consistente."
}

if ($script:failures -gt 0) {
    Write-Output "Resultado: FALLA — $script:failures de $script:checks verificación(es) con error."
    exit 1
}
Write-Output "Resultado: PASA — $script:checks verificación(es) correctas."
exit 0

