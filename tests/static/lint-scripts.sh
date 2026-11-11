
#!/usr/bin/env bash
# =============================================================================
# lint-scripts.sh · Revisión estática de los scripts de bash con shellcheck.
#
# Revisa todos los .sh del repositorio (scripts/linux, scripts/aws y tests/) en dos pasos:
#   1. bash -n: el archivo se puede leer sin errores de sintaxis.
#   2. shellcheck: sin hallazgos de ningún nivel (error, warning, info, style).
#      Si shellcheck no está instalado, usa la imagen de Docker
#      koalaman/shellcheck:stable.
#
# Los scripts de PowerShell se revisan con tests/static/Lint-Scripts.ps1.
#
# Uso:    tests/static/lint-scripts.sh [archivo.sh ...]
#         (sin argumentos revisa todos los .sh de scripts/ y tests/)
# Salida: "✅ OK:" o "❌ FALLA:" por archivo; código 0 si todo pasa y 1 si algo
#         falla. No usa AWS ni modifica archivos.
# =============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --help: muestra este encabezado.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
  exit 0
fi
cd "$repo_root"

# Archivos a revisar, como rutas relativas a la raíz del repositorio (así
# funcionan igual con shellcheck local y dentro del contenedor).
if (( $# > 0 )); then
  files=("$@")
else
  mapfile -t files < <(find scripts tests -type f -name '*.sh' | sort)
fi
if (( ${#files[@]} == 0 )); then
  echo "❌ FALLA: no se encontraron scripts .sh para revisar."
  exit 1
fi

# Elige cómo ejecutar shellcheck: local o con Docker.
if command -v shellcheck >/dev/null 2>&1; then
  run_shellcheck() { shellcheck "$@"; }
  how="shellcheck $(shellcheck --version | awk '/^version:/ {print $2}') local"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # En Git Bash de Windows, "pwd -W" da la ruta con letra de unidad que Docker
  # entiende; MSYS_NO_PATHCONV evita que Git Bash reescriba "/mnt".
  host_dir="$(pwd -W 2>/dev/null || pwd)"
  run_shellcheck() {
    MSYS_NO_PATHCONV=1 docker run --rm -v "$host_dir:/mnt:ro" -w /mnt koalaman/shellcheck:stable "$@"
  }
  how="shellcheck en Docker (koalaman/shellcheck:stable)"
else
  echo "❌ FALLA: no hay shellcheck ni Docker. Instala shellcheck o inicia Docker Desktop."
  exit 1
fi
echo "ℹ️  Usando $how para ${#files[@]} archivo(s)."

failures=0
for file in "${files[@]}"; do
  # 1. Sintaxis.
  if ! syntax_output="$(bash -n "$file" 2>&1)"; then
    echo "❌ FALLA: $file (bash -n)"
    echo "$syntax_output"
    failures=$((failures + 1))
    continue
  fi
  # 2. shellcheck con todas las severidades; --external-sources sigue los "source".
  if lint_output="$(run_shellcheck --severity=style --external-sources "$file" 2>&1)"; then
    echo "✅ OK: $file"
  else
    echo "❌ FALLA: $file (shellcheck)"
    echo "$lint_output"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures de ${#files[@]} archivo(s) con hallazgos."
  exit 1
fi
echo "Resultado: PASA — ${#files[@]} archivo(s) sin hallazgos de shellcheck."

