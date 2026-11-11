
#!/usr/bin/env bash
# Registra la IP de túnel de este equipo (rango del client CIDR) en la zona
# privada de Route 53, solo cuando cambia. Lo ejecuta vpn-hub-dns.timer.
#
# Configuración: /etc/vpn-hub/dns-updater.env (generado por Terraform):
#   RECORD_NAME, HOSTED_ZONE_ID, CLIENT_CIDR, AWS_CONFIG_FILE, AWS_PROFILE
# Credenciales: IAM Roles Anywhere vía aws_signing_helper (credential_process).
set -euo pipefail

ENV_FILE="${VPN_HUB_ENV_FILE:-/etc/vpn-hub/dns-updater.env}"
STATE_DIR="${VPN_HUB_STATE_DIR:-/var/lib/vpn-hub}"
TTL=60

# shellcheck source=/dev/null
source "$ENV_FILE"
export AWS_CONFIG_FILE AWS_PROFILE

: "${RECORD_NAME:?falta RECORD_NAME}"
: "${HOSTED_ZONE_ID:?falta HOSTED_ZONE_ID}"
: "${CLIENT_CIDR:?falta CLIENT_CIDR}"

tunnel_ip="$(python3 - "$CLIENT_CIDR" <<'PY'
import ipaddress, json, subprocess, sys
net = ipaddress.ip_network(sys.argv[1])
for iface in json.loads(subprocess.check_output(["ip", "-j", "-4", "addr", "show"])):
    for addr in iface.get("addr_info", []):
        if ipaddress.ip_address(addr["local"]) in net:
            print(addr["local"])
            sys.exit(0)
sys.exit(1)
PY
)" || {
  echo "Sin IP en ${CLIENT_CIDR}: la VPN no está conectada. Nada que hacer."
  exit 0
}

mkdir -p "$STATE_DIR"
cache_file="${STATE_DIR}/last-ip"
if [[ -f "$cache_file" && "$(cat "$cache_file")" == "$tunnel_ip" ]]; then
  exit 0
fi

change_batch="$(cat <<JSON
{
  "Comment": "vpn-hub: IP de tunel de ${RECORD_NAME}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${RECORD_NAME}",
      "Type": "A",
      "TTL": ${TTL},
      "ResourceRecords": [{ "Value": "${tunnel_ip}" }]
    }
  }]
}
JSON
)"

change_id="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$change_batch" \
  --query 'ChangeInfo.Id' \
  --output text)"

echo "$tunnel_ip" > "$cache_file"
echo "${RECORD_NAME} -> ${tunnel_ip} (${change_id})"

