
#!/usr/bin/env bash
# Instala en un equipo Ubuntu (workstation-1) el cliente OpenVPN como servicio con
# el perfil de vpn-hub, DETENIDO y SIN arranque automático (aún no la enciendes).
# Tú lo enciendes cuando necesites el túnel con "vpn-hub-service on" y lo apagas al
# regresar con "vpn-hub-service off". Si el paquete lo incluye, instala también
# el actualizador de DNS, que solo actúa mientras la VPN está conectada.
#
# Uso (dentro del paquete que genera Terraform en terraform/hub/out/<equipo>/):
#   sudo bash ./install.sh   (con "bash": una copia desde Windows pierde el permiso de ejecución)
# Uso desde el repositorio:
#   sudo bash scripts/linux/install.sh terraform/hub/out/workstation-1
#
# El actualizador de DNS necesita, además (no los instala este script):
#   - AWS CLI v2:          https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
#   - aws_signing_helper:  https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html
#                          copiado en /usr/local/bin/aws_signing_helper
#   - python3:             Ubuntu lo trae
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ejecuta con sudo." >&2
  exit 1
fi
if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
  echo "Ejecútalo con sudo desde tu usuario (no como root directo): la regla de sudo se crea para ese usuario." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
device_dir="$(cd "${1:-$script_dir}" && pwd)"
service="openvpn-client@vpn-hub"

shopt -s nullglob
profiles=("$device_dir"/*.ovpn)
if (( ${#profiles[@]} != 1 )); then
  echo "Se esperaba exactamente un perfil .ovpn en $device_dir (hay ${#profiles[@]})." >&2
  exit 1
fi
ovpn_file="${profiles[0]}"
# El perfil trae "dhcp-option DOMAIN <zona>": esa zona se resuelve por la VPN.
dns_domain="$(awk '$1 == "dhcp-option" && $2 == "DOMAIN" {print $3; exit}' "$ovpn_file")"

# --- 1. Cliente OpenVPN como servicio (detenido) ----------------------------
echo "==> [1/3] Servicio $service con $(basename "$ovpn_file")"
apt-get update -qq
apt-get install -y openvpn openvpn-systemd-resolved

install -d -m 0755 /etc/openvpn/client
install -m 0600 -o root -g root "$ovpn_file" /etc/openvpn/client/vpn-hub.conf
# Para que este equipo resuelva *.<zona> con el DNS de la VPN (systemd-resolved),
# solo mientras el túnel está arriba. El perfil de la tableta no lleva estas líneas.
cat >> /etc/openvpn/client/vpn-hub.conf <<EOF

# --- Agregado por install.sh: DNS de la VPN solo para ${dns_domain:-la zona privada} ---
script-security 2
up /etc/openvpn/update-systemd-resolved
up-restart
down /etc/openvpn/update-systemd-resolved
down-pre
${dns_domain:+dhcp-option DOMAIN-ROUTE $dns_domain}
EOF

# El túnel queda apagado hasta que alguien ejecute vpn-hub-service on.
systemctl disable --now "$service" >/dev/null 2>&1 || true
echo "    Instalado, detenido y sin arranque automático."

# --- 2. Regla de sudo limitada para vpn-hub-service -------------------------
echo "==> [2/3] vpn-hub-service y regla de sudo para $SUDO_USER"
install -m 0755 "$script_dir/vpn-hub-service.sh" /usr/local/bin/vpn-hub-service
sudoers_tmp="$(mktemp)"
cat > "$sudoers_tmp" <<EOF
# vpn-hub: permite a $SUDO_USER encender y apagar SOLO el servicio de la VPN sin contraseña.
$SUDO_USER ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now $service, /usr/bin/systemctl disable --now $service
EOF
if visudo -cf "$sudoers_tmp" >/dev/null; then
  install -m 0440 -o root -g root "$sudoers_tmp" /etc/sudoers.d/vpn-hub
  echo "    Listo. Úsalo con: vpn-hub-service on | off | status"
else
  echo "    La regla de sudo no pasó la validación de visudo; no se instaló." >&2
fi
rm -f "$sudoers_tmp"

# --- 3. Actualizador de DNS (solo equipos de la LAN) --------------------------
echo "==> [3/3] Actualizador de DNS"
certs=("$device_dir"/*.crt)
keys=("$device_dir"/*.key)
if (( ${#certs[@]} != 1 || ${#keys[@]} != 1 )) || [[ ! -f "$device_dir/aws-config" || ! -f "$device_dir/dns-updater.env" ]]; then
  echo "    Este paquete no incluye el actualizador de DNS. Listo."
  exit 0
fi

missing=()
command -v aws >/dev/null || missing+=("AWS CLI v2 (aws)")
[[ -x /usr/local/bin/aws_signing_helper ]] || missing+=("/usr/local/bin/aws_signing_helper")
command -v python3 >/dev/null || missing+=("python3")
if (( ${#missing[@]} > 0 )); then
  echo "    Omitido: faltan ${missing[*]}."
  echo "    Instálalos (pasos en docs/client-setup.md, sección DNS updater tools) y vuelve a ejecutar: sudo bash $0 ${1:-}"
  exit 0
fi

install -d -m 0755 /etc/vpn-hub
install -m 0644 "${certs[0]}" "/etc/vpn-hub/$(basename "${certs[0]}")"
install -m 0600 "${keys[0]}" "/etc/vpn-hub/$(basename "${keys[0]}")"
install -m 0644 "$device_dir/aws-config" /etc/vpn-hub/aws-config
install -m 0644 "$device_dir/dns-updater.env" /etc/vpn-hub/dns-updater.env

install -m 0755 "$script_dir/vpn-hub-dns-update.sh" /usr/local/sbin/vpn-hub-dns-update.sh
install -m 0644 "$script_dir/vpn-hub-dns.service" /etc/systemd/system/vpn-hub-dns.service
install -m 0644 "$script_dir/vpn-hub-dns.timer" /etc/systemd/system/vpn-hub-dns.timer

# El timer revisa cada 2 minutos; mientras la VPN está apagada no hace nada.
systemctl daemon-reload
systemctl enable --now vpn-hub-dns.timer >/dev/null

echo "    Instalado. Registrará el nombre del equipo unos 2 minutos después de 'vpn-hub-service on'."

