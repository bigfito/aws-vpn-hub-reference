
#!/usr/bin/env bash
# =============================================================================
# check-terraform-docs.sh · ¿El código Terraform está documentado para un junior?
#
# Comprueba las reglas de la guía de estilo de este repositorio en cada archivo .tf de
# terraform/bootstrap y terraform/hub:
#   1. El archivo empieza con un encabezado de al menos 3 líneas de comentario.
#   2. Cada bloque de nivel superior (resource, data, variable, output, locals,
#      module, check, terraform, provider, moved, import) tiene un comentario en
#      la línea inmediatamente anterior.
#   3. Cada variable y cada output tienen "description".
#   4. Al menos el 25 % de las líneas no vacías son comentarios.
#
# Uso:    tests/static/check-terraform-docs.sh [carpeta ...]
#         (sin argumentos revisa terraform/bootstrap y terraform/hub)
# Salida: una línea "✅ OK:" por archivo correcto y una "❌ FALLA:" por cada problema; código 0 si todo
#         pasa y 1 si algo falla. No usa AWS ni modifica archivos.
# =============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# --help: muestra este encabezado.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
  exit 0
fi

if (( $# > 0 )); then
  folders=("$@")
else
  folders=("$repo_root/terraform/bootstrap" "$repo_root/terraform/hub")
fi
min_header_lines=3
min_comment_percent=25
failures=0

# Revisa un archivo con awk y escribe una línea por problema encontrado.
check_file() {
  awk -v min_header="$min_header_lines" -v min_pct="$min_comment_percent" '
    # Línea de comentario completa: empieza (tras espacios) con # o //.
    function is_comment(line) { return line ~ /^[ \t]*(#|\/\/)/ }

    {
      sub(/\r$/, "")                       # tolera finales de línea de Windows
      lines[NR] = $0
      if ($0 !~ /^[ \t]*$/) non_blank++
      if (is_comment($0)) comments++
    }

    END {
      # 1. Encabezado del archivo.
      header = 0
      for (i = 1; i <= NR && is_comment(lines[i]); i++) header++
      if (header < min_header) printf "encabezado de %d líneas de comentario (mínimo %d)\n", header, min_header

      # 2 y 3. Bloques de nivel superior.
      for (i = 1; i <= NR; i++) {
        if (lines[i] !~ /^(resource|data|variable|output|locals|module|check|terraform|provider|moved|import)([ \t{]|$)/) continue
        name = lines[i]; sub(/[ \t]*\{[ \t]*$/, "", name)
        if (i == 1 || !is_comment(lines[i - 1])) printf "línea %d: falta un comentario justo antes de %s\n", i, name
        if (lines[i] ~ /^(variable|output)[ \t]/) {
          has_description = 0
          for (j = i + 1; j <= NR && lines[j] !~ /^\}/; j++) if (lines[j] ~ /^[ \t]+description[ \t]*=/) has_description = 1
          if (!has_description) printf "línea %d: %s no tiene description\n", i, name
        }
      }

      # 4. Proporción de comentarios.
      pct = non_blank ? int(comments * 100 / non_blank) : 0
      if (pct < min_pct) printf "solo %d%% de las líneas no vacías son comentarios (mínimo %d%%)\n", pct, min_pct
    }
  ' "$1"
}

shopt -s nullglob
for folder in "${folders[@]}"; do
  files=("$folder"/*.tf)
  if (( ${#files[@]} == 0 )); then
    echo "❌ FALLA: no hay archivos .tf en $folder"
    failures=$((failures + 1))
    continue
  fi
  for file in "${files[@]}"; do
    relative="${file#"$repo_root"/}"
    problems="$(check_file "$file")"
    if [[ -z "$problems" ]]; then
      echo "✅ OK: $relative"
    else
      while IFS= read -r problem; do
        echo "❌ FALLA: $relative: $problem"
      done <<< "$problems"
      failures=$((failures + 1))
    fi
  done
done

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures archivo(s) no cumplen la guía de estilo de este repositorio."
  exit 1
fi
echo "Resultado: PASA — todos los archivos .tf cumplen la guía de estilo de este repositorio."

