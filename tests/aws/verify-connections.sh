
#!/usr/bin/env bash
# =============================================================================
# verify-connections.sh · ¿Qué equipos están conectados a la VPN? (F4–F8)
#
# Comprueba, en SOLO LECTURA, las conexiones activas del endpoint vpn-hub-cvpn.
# El nombre de cada conexión es el CN del certificado, que es el nombre del
# dispositivo (workstation-2, workstation-1, tablet-1).
#
#   verify-connections.sh <cn> [<cn> ...]
#       Pasa si cada CN indicado tiene una conexión activa; muestra su IP de
#       túnel (10.81.x.x). AWS tarda 1–3 minutos en listar una conexión nueva
#       (en T4.2 tardó unos 2): si el equipo ya tiene IP de túnel, espera y repite.
#   verify-connections.sh --none
#       Pasa si NO hay ninguna conexión activa (por ejemplo, tras desinstalar
#       los equipos con la asociación encendida: T8.1). Si el endpoint no
#       existe, tampoco puede haber conexiones y la prueba pasa.
#       ⚠️ Con el endpoint DESASOCIADO no es concluyente: AWS sigue listando
#       como active las conexiones ya cortadas hasta que se vuelve a asociar
#       (comprobado en T7.1). Ahí, la prueba del corte es la bitácora de cada
#       equipo; el script lo advierte.
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-connections.sh workstation-2 workstation-1
#         AWS_PROFILE=vpn-hub tests/aws/verify-connections.sh --none
#         tests/aws/verify-connections.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if (( $# == 0 )); then show_help; exit 2; fi
if [[ "$1" == "--help" || "$1" == "-h" ]]; then show_help; exit 0; fi
expect_none=false
if [[ "$1" == "--none" ]]; then
  expect_none=true
  if (( $# > 1 )); then echo "--none no admite nombres de dispositivo (usa --help)"; exit 2; fi
fi

require_session
info "Perfil $PROFILE, región $REGION."

endpoint_id="$(find_endpoint_id)"
if [[ -z "$endpoint_id" ]]; then
  if $expect_none; then
    ok "no existe el endpoint ${PROJECT}-cvpn, así que no hay conexiones activas"
  else
    fail "no existe el endpoint ${PROJECT}-cvpn en $REGION (¿ya se aplicó el hub?)"
  fi
  finish
fi

# Conexiones activas: una línea "<CN> <IP de túnel>" por conexión.
active="$(aws_ro ec2 describe-client-vpn-connections --client-vpn-endpoint-id "$endpoint_id" \
  --query "Connections[?Status.Code=='active'].[CommonName,ClientIp]" --output text)"
active="$(sed '/^[[:space:]]*$/d' <<<"$active")"

if $expect_none; then
  if [[ -z "$active" ]]; then
    ok "no hay conexiones activas"
  else
    fail "hay conexiones activas: $(tr '\t\n' ': ' <<<"$active")"
    # Comprobado en T7.1: sin asociación, AWS no procesa los cierres y sigue
    # listando como active las conexiones ya cortadas (las limpia al asociar).
    status="$(aws_ro ec2 describe-client-vpn-endpoints --client-vpn-endpoint-ids "$endpoint_id" \
      --query 'ClientVpnEndpoints[0].Status.Code' --output text)"
    if [[ "$status" == "pending-associate" ]]; then
      warn "el endpoint está desasociado: AWS puede seguir listando conexiones ya cortadas, así que este resultado NO es concluyente. Revisa la bitácora de cada equipo (vpn-hub-service status)."
    fi
  fi
  finish
fi

for cn in "$@"; do
  ip="$(awk -v cn="$cn" '$1 == cn { print $2; exit }' <<<"$active")"
  if [[ -n "$ip" ]]; then
    ok "$cn conectado con IP de túnel $ip"
  else
    fail "$cn no tiene una conexión activa. ¿Está encendida la asociación (consola o vpn-hub.sh) y 'vpn-hub-service on' en el equipo?"
  fi
done

finish

