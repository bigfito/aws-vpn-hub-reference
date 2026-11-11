
#Requires -Version 5.1

<#
.SYNOPSIS
    Registra la IP de túnel de este equipo (rango del client CIDR) en la zona
    privada de Route 53, solo cuando cambia. Lo ejecuta la tarea programada
    "vpn-hub-dns" cada 2 minutos.

.DESCRIPTION
    Lee C:\ProgramData\vpn-hub\dns-updater.json (generado por Terraform).
    Las credenciales salen de IAM Roles Anywhere vía aws_signing_helper
    (credential_process en C:\ProgramData\vpn-hub\aws-config).
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = "$env:ProgramData\vpn-hub\dns-updater.json"
)

$ErrorActionPreference = 'Stop'
$ttl = 60
$stateDir = "$env:ProgramData\vpn-hub"
$cacheFile = Join-Path $stateDir 'last-ip.txt'

function ConvertTo-UInt32([System.Net.IPAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-InCidr([string]$Ip, [string]$Cidr) {
    $network, $bits = $Cidr.Split('/')
    # En PowerShell 5.1 el literal 0xFFFFFFFF es Int32 (-1); se usa el decimal.
    $allOnes = [uint64]4294967295
    $mask = if ([int]$bits -eq 0) { [uint32]0 } else { [uint32](($allOnes -shl (32 - [int]$bits)) -band $allOnes) }
    $ipValue = ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($Ip))
    $netValue = ConvertTo-UInt32 ([System.Net.IPAddress]::Parse($network))
    return (($ipValue -band $mask) -eq ($netValue -band $mask))
}

$config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
$env:AWS_CONFIG_FILE = $config.AwsConfigFile
$env:AWS_PROFILE = $config.AwsProfile

$tunnelIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { Test-InCidr $_.IPAddress $config.ClientCidr } |
    Select-Object -First 1 -ExpandProperty IPAddress

if (-not $tunnelIp) {
    Write-Output "Sin IP en $($config.ClientCidr): la VPN no está conectada. Nada que hacer."
    exit 0
}

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
if ((Test-Path $cacheFile) -and ((Get-Content -Raw $cacheFile).Trim() -eq $tunnelIp)) {
    exit 0
}

$changeBatch = @{
    Comment = "vpn-hub: IP de tunel de $($config.RecordName)"
    Changes = @(@{
        Action            = 'UPSERT'
        ResourceRecordSet = @{
            Name            = $config.RecordName
            Type            = 'A'
            TTL             = $ttl
            ResourceRecords = @(@{ Value = $tunnelIp })
        }
    })
} | ConvertTo-Json -Depth 6

$batchFile = Join-Path $stateDir 'change-batch.json'
# La CLI de AWS no acepta UTF-8 con BOM: se escribe sin BOM.
[System.IO.File]::WriteAllText($batchFile, $changeBatch, (New-Object System.Text.UTF8Encoding $false))

$changeId = & aws route53 change-resource-record-sets `
    --hosted-zone-id $config.HostedZoneId `
    --change-batch "file://$batchFile" `
    --query 'ChangeInfo.Id' `
    --output text
if ($LASTEXITCODE -ne 0) {
    throw "aws route53 change-resource-record-sets falló con código $LASTEXITCODE"
}

Set-Content -Path $cacheFile -Value $tunnelIp -Encoding ascii
Write-Output "$($config.RecordName) -> $tunnelIp ($changeId)"

