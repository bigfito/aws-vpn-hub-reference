
#Requires -Version 5.1

<#
.SYNOPSIS
    Revisión estática de los scripts de PowerShell con PSScriptAnalyzer.

.DESCRIPTION
    Revisa todos los .ps1 del repositorio (scripts/windows y tests/) en tres pasos:

      1. Sintaxis: el analizador de PowerShell lee el archivo sin errores.
      2. Codificación: el archivo es UTF-8 con BOM. Windows PowerShell 5.1 lee
         los archivos sin BOM como ANSI y rompe los acentos y los emojis.
      3. PSScriptAnalyzer: sin hallazgos de severidad Error ni Warning. Las
         reglas que no apliquen a este proyecto se excluyen, con su razón, en
         tests/static/PSScriptAnalyzerSettings.psd1.

    Los scripts de bash se revisan con tests/static/lint-scripts.sh.

    Requiere el módulo PSScriptAnalyzer:
      Install-Module PSScriptAnalyzer -Scope CurrentUser

.PARAMETER Path
    Archivos .ps1 a revisar. Sin este parámetro revisa todos los de scripts/ y tests/.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\static\Lint-Scripts.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\static\Lint-Scripts.ps1 scripts\windows\Install-VpnHub.ps1 scripts\windows\vpn-hub-service.ps1

.NOTES
    Salida: "✅ OK:" o "❌ FALLA:" por archivo; código 0 si todo pasa y 1 si algo
    falla. No usa AWS ni modifica archivos.
#>
[CmdletBinding()]
param(
    # ValueFromRemainingArguments permite pasar varios archivos separados por
    # espacios también con "powershell -File" (que no entiende listas con comas).
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
# La consola de Windows usa otra página de códigos: sin esto, los emojis y los
# acentos de la salida se ven como símbolos raros.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$settingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

# Archivos a revisar.
if ($Path) {
    $files = $Path | ForEach-Object { Get-Item -LiteralPath $_ }
} else {
    $files = foreach ($folder in 'scripts', 'tests') {
        Get-ChildItem -Path (Join-Path $repoRoot $folder) -Recurse -File -Filter '*.ps1'
    }
    $files = $files | Sort-Object FullName
}
if (-not $files) {
    Write-Output '❌ FALLA: no se encontraron scripts .ps1 para revisar.'
    exit 1
}

# PSScriptAnalyzer debe estar instalado.
$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if (-not $analyzer) {
    Write-Output '❌ FALLA: falta el módulo PSScriptAnalyzer. Instálalo con: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 1
}
Import-Module $analyzer.Path
Write-Output "ℹ️  Usando PSScriptAnalyzer $($analyzer.Version) para $(@($files).Count) archivo(s)."

$failures = 0
foreach ($file in $files) {
    # Ruta relativa a la raíz del repositorio (o completa, si el archivo está fuera).
    $relative = if ($file.FullName.StartsWith($repoRoot)) { $file.FullName.Substring($repoRoot.Length + 1) } else { $file.FullName }
    $problems = New-Object System.Collections.Generic.List[string]

    # 1. Sintaxis.
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        $problems.Add("sintaxis, línea $($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }

    # 2. UTF-8 con BOM (EF BB BF).
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $problems.Add('codificación: no es UTF-8 con BOM (Windows PowerShell 5.1 lo leería como ANSI)')
    }

    # 3. PSScriptAnalyzer (solo si la sintaxis es válida).
    if (-not $parseErrors) {
        $findings = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsFile
        foreach ($finding in $findings) {
            $problems.Add("$($finding.Severity) $($finding.RuleName), línea $($finding.Line): $($finding.Message)")
        }
    }

    if ($problems.Count -eq 0) {
        Write-Output "✅ OK: $relative"
    } else {
        Write-Output "❌ FALLA: $relative"
        $problems | ForEach-Object { Write-Output "    $_" }
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Output "Resultado: FALLA — $failures de $(@($files).Count) archivo(s) con hallazgos."
    exit 1
}
Write-Output "Resultado: PASA — $(@($files).Count) archivo(s) sin errores ni advertencias de PSScriptAnalyzer."
exit 0

