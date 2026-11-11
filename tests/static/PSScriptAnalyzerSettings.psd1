
# =============================================================================
# PSScriptAnalyzerSettings.psd1 · Reglas de PSScriptAnalyzer para vpn-hub
#
# Lo usa tests/static/Lint-Scripts.ps1. Se reportan los hallazgos de severidad
# Error y Warning. Cada regla excluida lleva su razón; no excluyas reglas sin
# escribir por qué.
# =============================================================================
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @()
}

