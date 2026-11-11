
#!/usr/bin/env bash
# =============================================================================
# check-terraform.sh · Formato y validación de los dos stacks de Terraform.
#
#   1. terraform fmt -check -recursive en terraform/ (formato canónico).
#   2. terraform init -backend=false + terraform validate en terraform/bootstrap
#      y terraform/hub (sintaxis, referencias y tipos).
#
# No usa credenciales de AWS ni el estado remoto: "-backend=false" inicializa
# solo los proveedores. Si un stack ya tiene su backend inicializado (existe
# .terraform/terraform.tfstate, como el hub tras T3.2), se omite el init: con un
# backend S3 configurado, hasta "init -backend=false" pide credenciales, y
# validate no lo necesita. No modifica el código.
#
# Uso:    tests/static/check-terraform.sh
#         TERRAFORM=/ruta/a/terraform tests/static/check-terraform.sh
# Salida: "✅ OK:" o "❌ FALLA:" por paso; código 0 si todo pasa y 1 si algo falla.
# =============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --help: muestra este encabezado.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
  exit 0
fi
terraform_bin="${TERRAFORM:-terraform}"
failures=0

if ! command -v "$terraform_bin" >/dev/null 2>&1; then
  echo "❌ FALLA: no se encontró Terraform ('$terraform_bin'). Abre una terminal nueva o define TERRAFORM con su ruta."
  exit 1
fi

# 1. Formato.
if "$terraform_bin" -chdir="$repo_root/terraform" fmt -check -recursive >/dev/null; then
  echo "✅ OK: terraform fmt -check (formato canónico)"
else
  echo "❌ FALLA: terraform fmt -check. Corrige con: terraform -chdir=terraform fmt -recursive"
  failures=$((failures + 1))
fi

# 2. Inicialización sin backend y validación de cada stack.
for stack in bootstrap hub; do
  dir="$repo_root/terraform/$stack"
  if [[ -f "$dir/.terraform/terraform.tfstate" ]]; then
    echo "ℹ️  $stack ya tiene su backend inicializado: se omite el init y se usan sus proveedores."
  elif ! init_output="$("$terraform_bin" -chdir="$dir" init -backend=false -input=false -no-color 2>&1)"; then
    echo "❌ FALLA: terraform init ($stack)"
    echo "$init_output" | tail -5
    failures=$((failures + 1))
    continue
  fi
  if validate_output="$("$terraform_bin" -chdir="$dir" validate -no-color 2>&1)"; then
    echo "✅ OK: terraform validate ($stack)"
  else
    echo "❌ FALLA: terraform validate ($stack)"
    echo "$validate_output"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures paso(s) con error."
  exit 1
fi
echo "Resultado: PASA — formato y validación correctos en bootstrap y hub."

