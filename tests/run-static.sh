
#!/usr/bin/env bash
# =============================================================================
# run-static.sh · Todas las pruebas que no usan AWS, en un solo comando.
#
# Es la puerta de F1 y se ejecuta después de cualquier cambio en Terraform o en
# los scripts, antes de un "terraform plan" (README). Corre, en orden:
#   1. tests/static/check-terraform-docs.sh   documentación para un junior
#   2. tests/static/check-terraform.sh        terraform fmt y validate
#   3. terraform test                         pruebas unitarias (hub y bootstrap)
#   4. tests/static/lint-scripts.sh           shellcheck de los .sh
#   5. tests/static/test-vpn-hub-script.sh    vpn-hub.sh (CloudShell) con una AWS CLI simulada
#   6. tests/static/Lint-Scripts.ps1          PSScriptAnalyzer de los .ps1
#   7. tests/static/security-scan.sh          trivy config sin HIGH/CRITICAL
#
# Ninguna usa credenciales de AWS ni modifica el código. Cada paso muestra su
# línea "Resultado"; si un paso falla, muestra su salida completa.
#
# Requisitos: Terraform, Docker (shellcheck y trivy) y PowerShell con el módulo
# PSScriptAnalyzer (Windows PowerShell o pwsh).
#
# Opciones:
#   --sin-powershell   omite el paso 6 (por ejemplo, en un Linux sin pwsh); el
#                      resultado lo indica y no cuenta como puerta de F1.
#
# Uso:    tests/run-static.sh [--sin-powershell]
#         TERRAFORM=/ruta/a/terraform tests/run-static.sh
# Salida: "✅ OK:" o "❌ FALLA:" por paso; código 0 si todo pasa y 1 si algo
#         falla.
# =============================================================================
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1
terraform_bin="${TERRAFORM:-terraform}"
skip_powershell=false

case "${1:-}" in
  --help | -h) awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"; exit 0 ;;
  --sin-powershell) skip_powershell=true ;;
  "") ;;
  *) echo "Opción desconocida: $1 (usa --help)"; exit 2 ;;
esac

failures=0
steps=0

# Ejecuta un paso. Uso: run_step "<nombre>" <comando...>
run_step() {
  local name="$1" output status
  shift
  steps=$((steps + 1))
  echo "▶️  [$steps] $name"
  output="$("$@" 2>&1)"
  status=$?
  if (( status == 0 )); then
    echo "✅ OK: $name — $(grep -E '^(Resultado|Success)' <<<"$output" | tail -1)"
  else
    echo "❌ FALLA: $name (código $status)"
    while IFS= read -r line; do echo "    $line"; done <<<"$output"
    failures=$((failures + 1))
  fi
}

# terraform test en los dos stacks (check-terraform.sh ya hizo el init).
# shellcheck disable=SC2329  # se invoca a través de run_step
terraform_tests() {
  local stack output summary="" result=0
  for stack in hub bootstrap; do
    if ! output="$("$terraform_bin" -chdir="terraform/$stack" test -no-color 2>&1)"; then
      echo "$output"
      result=1
    fi
    summary+="$stack: $(grep -E '^(Success|Failure)' <<<"$output" | tail -1) "
  done
  echo "Resultado: $summary"
  return "$result"
}

# Lint de PowerShell con Windows PowerShell o, si no existe, pwsh.
# shellcheck disable=SC2329  # se invoca a través de run_step
powershell_lint() {
  local shell
  if command -v powershell.exe >/dev/null 2>&1; then shell=powershell.exe
  elif command -v pwsh >/dev/null 2>&1; then shell=pwsh
  else echo "No hay PowerShell. Instala pwsh o usa --sin-powershell."; return 1
  fi
  "$shell" -NoProfile -ExecutionPolicy Bypass -File tests/static/Lint-Scripts.ps1
}

run_step "documentación de Terraform" bash tests/static/check-terraform-docs.sh
run_step "terraform fmt y validate" env TERRAFORM="$terraform_bin" bash tests/static/check-terraform.sh
run_step "terraform test (hub y bootstrap)" terraform_tests
run_step "shellcheck" bash tests/static/lint-scripts.sh
run_step "vpn-hub.sh simulado (sin AWS)" bash tests/static/test-vpn-hub-script.sh
if $skip_powershell; then
  echo "⚠️  [omitido] PSScriptAnalyzer (--sin-powershell)"
else
  run_step "PSScriptAnalyzer" powershell_lint
fi
run_step "trivy config" bash tests/static/security-scan.sh

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures de $steps paso(s) con error."
  exit 1
fi
if $skip_powershell; then
  echo "Resultado: PASA — $steps paso(s) correctos, SIN el lint de PowerShell (no vale como puerta de F1)."
else
  echo "Resultado: PASA — $steps paso(s) correctos."
fi
exit 0

