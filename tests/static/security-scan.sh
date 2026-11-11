
#!/usr/bin/env bash
# =============================================================================
# security-scan.sh · Escaneo de seguridad del código Terraform con trivy config.
#
# Busca configuraciones inseguras (buckets públicos, puertos abiertos a
# internet, cifrado apagado, etc.) en terraform/bootstrap y terraform/hub:
#   1. Puerta: ningún hallazgo HIGH ni CRITICAL, salvo las excepciones
#      justificadas en tests/static/trivy-excepciones.yaml.
#   2. Informe: lista los hallazgos MEDIUM y LOW, que no hacen fallar la prueba
#      pero conviene conocer (están en "Pendientes y deuda conocida" de
#      terraform/README.md).
#
# Usa trivy en Docker, fijado por versión y digest: la versión 0.69.4–0.69.6 de
# trivy fue comprometida en marzo de 2026 (CVE-2026-33634); no cambies la imagen
# sin revisar el aviso de seguridad de la nueva versión. El contenedor corre sin
# red (--network none) y con --skip-check-update: usa las reglas que trae la
# imagen y no descarga nada. Si no hay Docker, usa un trivy instalado (sin fijar
# por digest: muestra su versión junto a la probada, 0.76.1).
#
# Uso:    tests/static/security-scan.sh [carpeta]
#         (sin argumento revisa terraform/)
# Salida: "✅ OK:" o "❌ FALLA:" por paso; código 0 si pasa y 1 si algo falla.
#         No usa AWS ni modifica archivos.
# =============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --help: muestra este encabezado.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
  exit 0
fi
target="$(cd "${1:-$repo_root/terraform}" && pwd)"
ignore_file="$repo_root/tests/static/trivy-excepciones.yaml"
trivy_image="aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"

if [[ ! -f "$ignore_file" ]]; then
  echo "❌ FALLA: no existe $ignore_file."
  exit 1
fi

# Opciones comunes: sin descargar reglas nuevas, sin las carpetas .terraform
# (proveedores descargados) y con el archivo de excepciones.
common_args=(config --skip-check-update --skip-dirs "**/.terraform" --quiet)

# Elige cómo ejecutar trivy: Docker (versión fijada) o trivy local.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # En Git Bash de Windows, "pwd -W" da la ruta que Docker entiende y
  # MSYS_NO_PATHCONV evita que Git Bash reescriba las rutas del contenedor.
  target_host="$(cd "$target" && (pwd -W 2>/dev/null || pwd))"
  config_host="$(cd "$(dirname "$ignore_file")" && (pwd -W 2>/dev/null || pwd))"
  run_trivy() {
    MSYS_NO_PATHCONV=1 docker run --rm --network none \
      -v "$target_host:/scan:ro" -v "$config_host:/config:ro" \
      "$trivy_image" "${common_args[@]}" --ignorefile "/config/$(basename "$ignore_file")" "$@" /scan
  }
  how="trivy 0.76.1 en Docker (sin red)"
elif command -v trivy >/dev/null 2>&1; then
  run_trivy() { trivy "${common_args[@]}" --ignorefile "$ignore_file" "$@" "$target"; }
  how="trivy local ($(trivy --version | head -1)); la versión probada es 0.76.1"
else
  echo "❌ FALLA: no hay Docker ni trivy. Inicia Docker Desktop o instala trivy."
  exit 1
fi
echo "ℹ️  Usando $how sobre $target."

failures=0

# 1. Puerta: HIGH y CRITICAL. --exit-code 1 hace que trivy falle si encuentra algo.
if gate_output="$(run_trivy --severity HIGH,CRITICAL --exit-code 1 --format table 2>&1)"; then
  echo "✅ OK: sin hallazgos HIGH ni CRITICAL (fuera de las excepciones justificadas)"
else
  echo "❌ FALLA: hay hallazgos HIGH o CRITICAL. Corrígelos o justifícalos en tests/static/trivy-excepciones.yaml:"
  echo "$gate_output"
  failures=$((failures + 1))
fi

# 2. Informe: MEDIUM y LOW (no hacen fallar la prueba).
if info_output="$(run_trivy --severity MEDIUM,LOW --exit-code 0 --format table 2>&1)"; then
  findings="$(grep -E '^[A-Z0-9]+-[0-9]+ \((MEDIUM|LOW)\)' <<<"$info_output" || true)"
  if [[ -n "$findings" ]]; then
    echo "ℹ️  Hallazgos MEDIUM y LOW (informativos, ver terraform/README.md):"
    while IFS= read -r finding; do echo "    $finding"; done <<<"$findings"
  else
    echo "ℹ️  Sin hallazgos MEDIUM ni LOW."
  fi
else
  echo "❌ FALLA: trivy no pudo terminar el informe MEDIUM/LOW:"
  echo "$info_output"
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures paso(s) con error."
  exit 1
fi
echo "Resultado: PASA — trivy config sin hallazgos HIGH ni CRITICAL."

