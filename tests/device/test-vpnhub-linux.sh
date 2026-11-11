
#!/usr/bin/env bash
# =============================================================================
# test-vpnhub-linux.sh · ¿La VPN de workstation-1 (Ubuntu) está bien instalada? (T5.4)
#
# Se ejecuta EN workstation-1, con sudo (para validar la regla de sudo con
# visudo): sudo tests/device/test-vpnhub-linux.sh
# Solo lee: nunca enciende ni apaga el servicio (eso lo hace quien opera, con
# "vpn-hub-service on|off"). Detecta en qué estado está y revisa lo que toca:
#
#   Siempre:   perfil /etc/openvpn/client/vpn-hub.conf, comando
#              /usr/local/bin/vpn-hub-service, script update-systemd-resolved,
#              regla /etc/sudoers.d/vpn-hub válida (visudo) que deja a tu
#              usuario ejecutar "systemctl enable|disable --now
#              openvpn-client@vpn-hub" sin contraseña, timer vpn-hub-dns
#              habilitado y servidor SSH (ssh) activo. si ufw está activo, confirma que permite SSH
#              desde el rango de clientes de la VPN.
#   Apagado:   servicio openvpn-client@vpn-hub disabled e inactive, sin IP de
#              túnel.
#   Encendido: servicio enabled y active, IP de túnel 10.81.x.x, DNS 10.80.0.2
#              en la interfaz del túnel, el nombre propio resuelve a la IP de
#              túnel y se alcanza a los pares por su nombre de la VPN (por defecto
#              workstation-2:3389). Es un ensayo del camino de la tableta: en el día a
#              día los equipos de la LAN se comunican por la LAN.
#
# Opciones:
#   --sin-pares            no prueba el alcance a los otros equipos.
#   --par <nombre:puerto>  par a probar (se puede repetir); el nombre corto se
#                          completa con .vpn.example.internal.
#
# Uso:    sudo tests/device/test-vpnhub-linux.sh [--sin-pares | --par workstation-2:3389]
#         tests/device/test-vpnhub-linux.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. No usa AWS ni modifica nada.
# =============================================================================
set -euo pipefail

service="openvpn-client@vpn-hub"
zone="vpn.example.internal"
client_prefix="10.81."
vpc_dns="10.80.0.2"
peers=("workstation-2:3389")
check_peers=true
failures=0
checks=0

ok()   { checks=$((checks + 1)); echo "✅ OK: $*"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "❌ FALLA: $*"; }
info() { echo "ℹ️  $*"; }
show_help() { awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"; }

custom_peers=()
while (( $# > 0 )); do
  case "$1" in
    --help | -h) show_help; exit 0 ;;
    --sin-pares) check_peers=false ;;
    --par) shift; custom_peers+=("${1:?falta <nombre:puerto> después de --par}") ;;
    *) echo "Opción desconocida: $1 (usa --help)"; exit 2 ;;
  esac
  shift
done
(( ${#custom_peers[@]} > 0 )) && peers=("${custom_peers[@]}")

if (( EUID != 0 )) || [[ -z "${SUDO_USER:-}" ]]; then
  echo "❌ FALLA: ejecútalo con sudo desde tu usuario: sudo $0"
  exit 1
fi

# --- Siempre --------------------------------------------------------------------
if [[ -f /etc/openvpn/client/vpn-hub.conf ]]; then ok "perfil /etc/openvpn/client/vpn-hub.conf"; else fail "falta /etc/openvpn/client/vpn-hub.conf (ejecuta sudo bash ./install.sh)"; fi
if [[ -x /usr/local/bin/vpn-hub-service ]]; then ok "comando /usr/local/bin/vpn-hub-service"; else fail "falta /usr/local/bin/vpn-hub-service"; fi
if [[ -x /etc/openvpn/update-systemd-resolved ]]; then ok "script update-systemd-resolved (DNS de la VPN)"; else fail "falta /etc/openvpn/update-systemd-resolved (paquete openvpn-systemd-resolved)"; fi

if [[ -f /etc/sudoers.d/vpn-hub ]] && visudo -cf /etc/sudoers.d/vpn-hub >/dev/null 2>&1; then
  ok "regla /etc/sudoers.d/vpn-hub válida (visudo)"
else
  fail "falta /etc/sudoers.d/vpn-hub o no es válida"
fi
user_rules="$(sudo -l -U "$SUDO_USER" 2>/dev/null || true)"
if grep -q "NOPASSWD:.*systemctl enable --now $service" <<<"$user_rules" && grep -q "systemctl disable --now $service" <<<"$user_rules"; then
  ok "$SUDO_USER puede encender y apagar $service sin contraseña"
else
  fail "$SUDO_USER no tiene la regla sin contraseña para $service"
fi

if [[ "$(systemctl is-enabled vpn-hub-dns.timer 2>/dev/null || true)" == "enabled" ]]; then
  ok "timer vpn-hub-dns habilitado"
else
  fail "timer vpn-hub-dns no habilitado (vuelve a ejecutar install.sh con AWS CLI y aws_signing_helper)"
fi

# Servidor SSH: es lo que usa la tableta por la VPN (los equipos de la LAN se comunican por la LAN).
if [[ "$(systemctl is-active ssh 2>/dev/null || true)" == "active" ]]; then
  ok "servidor SSH (ssh) activo"
else
  fail "el servidor SSH no está activo: sudo apt install -y openssh-server"
fi

# El ejemplo no instala ufw. Si ya está activo, puede bloquear SSH desde la VPN.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
  info "AVISO: ufw está activo. Confirma que permite SSH desde el rango de clientes de la VPN."
else
  info "ufw no está activo. Si lo activas, permite SSH desde el rango de clientes."
fi

# --- Estado del servicio -----------------------------------------------------------
enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
active="$(systemctl is-active "$service" 2>/dev/null || true)"
tunnel_ip="$(ip -4 -o addr show 2>/dev/null | awk -v p="$client_prefix" 'index($4, p) == 1 { split($4, a, "/"); print a[1]; exit }')"
tunnel_dev="$(ip -4 -o addr show 2>/dev/null | awk -v p="$client_prefix" 'index($4, p) == 1 { print $2; exit }')"

if [[ "$enabled" != "enabled" && "$active" != "active" ]]; then
  info "estado: APAGADO (vpn-hub-service off)."
  ok "$service ${enabled:-desconocido} e ${active:-desconocido}"
  if [[ -z "$tunnel_ip" ]]; then ok "sin IP de túnel"; else fail "hay IP de túnel $tunnel_ip con el servicio apagado"; fi
elif [[ "$enabled" == "enabled" && "$active" == "active" ]]; then
  info "estado: ENCENDIDO (vpn-hub-service on)."
  ok "$service enabled y active"
  if [[ -n "$tunnel_ip" ]]; then
    ok "IP de túnel $tunnel_ip en $tunnel_dev"
  else
    fail "sin IP de túnel 10.81.x.x: ¿está encendida la asociación (consola o vpn-hub.sh)? (vpn-hub-service status)"
  fi
  if [[ "$(systemctl is-active vpn-hub-dns.timer 2>/dev/null || true)" == "active" ]]; then ok "timer vpn-hub-dns activo"; else fail "timer vpn-hub-dns no activo"; fi

  if [[ -n "$tunnel_dev" ]] && resolvectl dns "$tunnel_dev" 2>/dev/null | grep -qw "$vpc_dns"; then
    ok "DNS $vpc_dns en la interfaz $tunnel_dev"
  else
    fail "la interfaz del túnel no usa el DNS $vpc_dns (revisa update-systemd-resolved)"
  fi

  own_name="$(hostname -s).$zone"
  resolved="$(getent ahostsv4 "$own_name" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if [[ -n "$tunnel_ip" && "$resolved" == "$tunnel_ip" ]]; then
    ok "$own_name resuelve a la IP de túnel ($resolved)"
  else
    fail "$own_name resuelve a '${resolved:-nada}' (debe ser ${tunnel_ip:-la IP de túnel}); el actualizador corre cada 2 min"
  fi

  if $check_peers; then
    for peer in "${peers[@]}"; do
      host="${peer%%:*}"; port="${peer##*:}"
      [[ "$host" == *.* ]] || host="$host.$zone"
      if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        ok "alcance a $host:$port"
      else
        fail "no se alcanza $host:$port (¿el par está encendido y su firewall lo permite?)"
      fi
    done
  else
    info "se omite el alcance a los pares (--sin-pares)."
  fi
else
  fail "estado mixto: $service está '$enabled' y '$active'. Ejecuta vpn-hub-service off (o on) para dejarlo consistente."
fi

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures de $checks verificación(es) con error."
  exit 1
fi
echo "Resultado: PASA — $checks verificación(es) correctas."

