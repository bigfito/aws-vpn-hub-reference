
#!/usr/bin/env bash
# =============================================================================
# verify-hub.sh · ¿El hub de VPN está desplegado como dice el diseño? (T3.4, T7.4)
#
# Comprueba, en SOLO LECTURA (stack terraform/hub):
#   1. Existe el endpoint de Client VPN vpn-hub-cvpn. Si no existe, la prueba
#      termina de inmediato con un mensaje claro (el hub aún no se aplica).
#   2. Opciones del endpoint: client CIDR 10.81.0.0/22, DNS 10.80.0.2,
#      split-tunnel, UDP 443, sesión de 24 h sin desconexión al vencer y
#      bitácora de conexiones en /aws/clientvpn/vpn-hub.
#   3. Exactamente dos autorizaciones activas: 10.80.0.0/16 y 10.81.0.0/22.
#   4. Asociación (se enciende en la consola o con vpn-hub.sh):
#        - sin asociación: el endpoint está en pending-associate (correcto);
#        - con asociación: el endpoint está available, la subnet associated y
#          existen las rutas a la VPC y la ruta 10.81.0.0/22 -> local
#          (cliente-a-cliente; riesgo R1).
#   5. VPC vpn-hub-vpc sin internet gateway (no hay salida a internet).
#   6. Zona privada vpn.example.internal asociada a la VPC.
#   7. IAM Roles Anywhere: trust anchor vpn-hub-ca y perfil vpn-hub-dns-updater
#      habilitados; existe el rol de IAM vpn-hub-dns-updater.
#   8. Paquetes locales en terraform/hub/out/: un .ovpn por dispositivo y
#      aws-config en los equipos de la LAN (solo revisa que existan; no los lee).
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-hub.sh
#         tests/aws/verify-hub.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then show_help; exit 0; fi

require_session
info "Perfil $PROFILE, región $REGION."

# 1. Endpoint.
endpoint_id="$(find_endpoint_id)"
if [[ -z "$endpoint_id" ]]; then
  fail "no existe el endpoint de Client VPN ${PROJECT}-cvpn en $REGION: el hub aún no está desplegado (se crea en T3.4 con terraform apply)"
  finish
fi
ok "existe el endpoint ${PROJECT}-cvpn ($endpoint_id)"

# 2. Opciones del endpoint, en una sola consulta: la salida "text" de una lista
#    es una línea con los valores separados por tabuladores (los booleanos
#    salen como True/False y los vacíos como None).
IFS=$'\t' read -r status client_cidr dns_servers split_tunnel transport port timeout_hours \
  disconnect log_enabled log_group vpc_id <<<"$(aws_ro ec2 describe-client-vpn-endpoints \
  --client-vpn-endpoint-ids "$endpoint_id" --output text \
  --query "ClientVpnEndpoints[0].[Status.Code, ClientCidrBlock, join(',', DnsServers), SplitTunnel, TransportProtocol, VpnPort, SessionTimeoutHours, DisconnectOnSessionTimeout, ConnectionLogOptions.Enabled, ConnectionLogOptions.CloudwatchLogGroup, VpcId]")"

check_value() { # check_value <descripción> <valor real> <valor esperado>
  if [[ "$2" == "$3" ]]; then ok "$1 = $3"; else fail "$1 = '$2' (debe ser '$3')"; fi
}
check_value "client CIDR" "$client_cidr" "$VPN_CLIENT_CIDR"
check_value "servidores DNS" "$dns_servers" "$VPC_DNS_SERVER"
check_value "split-tunnel" "$split_tunnel" "True"
check_value "protocolo" "$transport" "udp"
check_value "puerto" "$port" "443"
check_value "duración de sesión (h)" "$timeout_hours" "24"
check_value "desconectar al vencer la sesión" "$disconnect" "False"
check_value "bitácora de conexiones" "$log_enabled" "True"
check_value "grupo de logs" "$log_group" "/aws/clientvpn/$PROJECT"

# 3. Autorizaciones.
rules="$(aws_ro ec2 describe-client-vpn-authorization-rules --client-vpn-endpoint-id "$endpoint_id" \
  --query "AuthorizationRules[?Status.Code=='active'].DestinationCidr" --output text | tr '\t' '\n' | sort | xargs)"
expected_rules="$(printf '%s\n' "$VPC_CIDR" "$VPN_CLIENT_CIDR" | sort | xargs)"
check_value "autorizaciones activas" "$rules" "$expected_rules"

# 4. Asociación y rutas.
associated="$(aws_ro ec2 describe-client-vpn-target-networks --client-vpn-endpoint-id "$endpoint_id" \
  --query "ClientVpnTargetNetworks[?Status.Code=='associated'].TargetNetworkId" --output text | xargs)"
if [[ -z "$associated" ]]; then
  info "asociación APAGADA (no se cobra por hora)."
  check_value "estado del endpoint sin asociación" "$status" "pending-associate"
else
  info "asociación ENCENDIDA en: $associated (se cobra por hora)."
  check_value "estado del endpoint con asociación" "$status" "available"
  routes="$(aws_ro ec2 describe-client-vpn-routes --client-vpn-endpoint-id "$endpoint_id" \
    --query "Routes[?Status.Code=='active'].[DestinationCidr,TargetSubnet]" --output text)"
  if awk -v cidr="$VPC_CIDR" '$1 == cidr { found = 1 } END { exit !found }' <<<"$routes"; then
    ok "ruta activa a la VPC $VPC_CIDR"
  else
    fail "falta la ruta activa a la VPC $VPC_CIDR"
  fi
  local_target="$(awk -v cidr="$VPN_CLIENT_CIDR" '$1 == cidr { print $2; exit }' <<<"$routes")"
  if [[ "$local_target" == "local" ]]; then
    ok "ruta activa $VPN_CLIENT_CIDR -> $local_target (cliente-a-cliente)"
  else
    fail "falta la ruta $VPN_CLIENT_CIDR -> local (hay: ${local_target:-ninguna}): créala en la consola o con vpn-hub.sh --enable (riesgo R1)"
  fi
fi

# 5. Sin internet gateway.
igws="$(aws_ro ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" \
  --query 'InternetGateways[].InternetGatewayId' --output text | xargs)"
if [[ -z "$igws" ]]; then ok "la VPC no tiene internet gateway"; else fail "la VPC tiene internet gateway: $igws"; fi

# 6. Zona privada asociada a la VPC.
zone_id="$(find_zone_id)"
if [[ -z "$zone_id" ]]; then
  fail "no existe la zona privada $ZONE_NAME"
else
  zone_vpcs="$(aws_ro route53 get-hosted-zone --id "$zone_id" --query 'VPCs[].VPCId' --output text)"
  if grep -qw "$vpc_id" <<<"$zone_vpcs"; then
    ok "zona privada $ZONE_NAME asociada a la VPC del hub"
  else
    fail "la zona privada $ZONE_NAME no está asociada a la VPC del hub"
  fi
fi

# 7. Roles Anywhere e IAM.
anchor="$(aws_ro rolesanywhere list-trust-anchors --query "trustAnchors[?name=='${PROJECT}-ca'].enabled | [0]" --output text)"
check_value "trust anchor ${PROJECT}-ca habilitado" "$anchor" "True"
profile_enabled="$(aws_ro rolesanywhere list-profiles --query "profiles[?name=='${PROJECT}-dns-updater'].enabled | [0]" --output text)"
check_value "perfil ${PROJECT}-dns-updater habilitado" "$profile_enabled" "True"
if aws_ro iam get-role --role-name "${PROJECT}-dns-updater" >/dev/null 2>&1; then
  ok "existe el rol de IAM ${PROJECT}-dns-updater"
else
  fail "no existe el rol de IAM ${PROJECT}-dns-updater"
fi

# 8. Paquetes locales.
out_dir="$REPO_ROOT/terraform/hub/out"
for device in "${ALL_DEVICES[@]}"; do
  if [[ -f "$out_dir/$device/${PROJECT}-${device}.ovpn" ]]; then
    ok "paquete: out/$device/${PROJECT}-${device}.ovpn"
  else
    fail "falta el paquete out/$device/${PROJECT}-${device}.ovpn (se genera con el apply del hub)"
  fi
done
for device in "${HOME_DEVICES[@]}"; do
  if [[ -f "$out_dir/$device/aws-config" ]]; then
    ok "paquete: out/$device/aws-config"
  else
    fail "falta out/$device/aws-config"
  fi
done

finish

