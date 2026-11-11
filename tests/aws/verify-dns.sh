
#!/usr/bin/env bash
# =============================================================================
# verify-dns.sh · ¿Cada equipo de la LAN registró su IP de túnel? (T4.3, T5.3, T7.1)
#
# Comprueba, en SOLO LECTURA, que el registro A <equipo>.vpn.example.internal
# de la zona privada coincida con la IP de túnel de la conexión activa de ese
# equipo (el actualizador de DNS la registra cada 2 minutos).
#
# Si falla con un registro viejo, espera 2 minutos y repite. Si el registro no
# existe, revisa la tarea vpn-hub-dns (Windows) o el timer vpn-hub-dns
# (Linux); un AccessDenied en su bitácora apunta al riesgo R6.
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-dns.sh workstation-2 workstation-1
#         tests/aws/verify-dns.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por equipo; código 0 si todo pasa y 1 si algo
#         falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if (( $# == 0 )); then show_help; exit 2; fi
if [[ "$1" == "--help" || "$1" == "-h" ]]; then show_help; exit 0; fi

require_session
info "Perfil $PROFILE, región $REGION."

endpoint_id="$(find_endpoint_id)"
zone_id="$(find_zone_id)"
if [[ -z "$endpoint_id" || -z "$zone_id" ]]; then
  fail "no existe el endpoint ${PROJECT}-cvpn o la zona privada $ZONE_NAME (¿ya se aplicó el hub?)"
  finish
fi

active="$(aws_ro ec2 describe-client-vpn-connections --client-vpn-endpoint-id "$endpoint_id" \
  --query "Connections[?Status.Code=='active'].[CommonName,ClientIp]" --output text)"

for device in "$@"; do
  record="${device}.${ZONE_NAME}"
  dns_ip="$(aws_ro route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='${record}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
    --output text | sed 's/^None$//')"
  tunnel_ip="$(awk -v cn="$device" '$1 == cn { print $2; exit }' <<<"$active")"
  if [[ -z "$tunnel_ip" ]]; then
    fail "$device no tiene una conexión activa; sin ella no hay IP que comparar (verify-connections.sh $device)"
  elif [[ -z "$dns_ip" ]]; then
    fail "no existe el registro A $record (el actualizador de DNS de $device aún no corre o falla)"
  elif [[ "$dns_ip" == "$tunnel_ip" ]]; then
    ok "$record = $dns_ip, igual a su IP de túnel"
  else
    fail "$record = $dns_ip, pero su IP de túnel es $tunnel_ip (espera 2 minutos y repite)"
  fi
done

finish

