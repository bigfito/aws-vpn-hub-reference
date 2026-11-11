
#!/usr/bin/env bash
# Enciende o apaga la VPN de vpn-hub en este equipo (workstation-1).
#
#   vpn-hub-service on      Habilita el servicio openvpn-client@vpn-hub y lo
#                           arranca. Queda con arranque automático: si el equipo
#                           se reinicia mientras estás fuera, vuelve a conectar solo.
#   vpn-hub-service off     Detiene el servicio y quita el arranque automático.
#   vpn-hub-service status  Muestra el estado sin cambiar nada.
#
# No pide contraseña: install.sh crea /etc/sudoers.d/vpn-hub, que permite a tu
# usuario ejecutar SIN contraseña únicamente estos dos comandos:
#   /usr/bin/systemctl enable --now openvpn-client@vpn-hub
#   /usr/bin/systemctl disable --now openvpn-client@vpn-hub
#
# Este script solo controla el equipo. La asociación del endpoint (lo que cobra
# AWS por hora) se enciende y apaga en la consola de AWS o con vpn-hub.sh; si está apagada, el
# servicio sigue reintentando y conecta solo unos minutos después de encenderla.
set -euo pipefail

service="openvpn-client@vpn-hub"
systemctl_bin="/usr/bin/systemctl"

# IP de túnel (interfaz tun*), si la hay.
tunnel_ip() {
  ip -4 -o addr show | awk '$2 ~ /^tun[0-9]+$/ {split($4, a, "/"); print a[1]; exit}'
}

show_status() {
  local enabled active ip
  enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  active="$(systemctl is-active "$service" 2>/dev/null || true)"
  ip="$(tunnel_ip)"
  echo "Servicio $service"
  echo "  Arranque automático: ${enabled:-desconocido}   (enabled = sí, disabled = no)"
  echo "  Estado:              ${active:-desconocido}"
  echo "  IP de túnel:         ${ip:-ninguna (sin conexión)}"
  # Con persist-tun la IP puede quedarse aunque la conexión se haya caído:
  # la última línea de la bitácora dice si está conectado o reintentando.
  echo "  Última bitácora:     $(journalctl -u "$service" -n 1 -o cat --no-pager 2>/dev/null || echo 'sin acceso (agrega tu usuario al grupo adm)')"
}

# Ejecuta systemctl con sudo sin pedir contraseña (regla de /etc/sudoers.d/vpn-hub).
run_systemctl() {
  if ! sudo -n "$systemctl_bin" "$@" "$service"; then
    echo "No se pudo ejecutar 'systemctl $* $service' sin contraseña." >&2
    echo "¿Ya ejecutaste 'sudo bash ./install.sh'? Crea la regla /etc/sudoers.d/vpn-hub." >&2
    exit 1
  fi
}

case "${1:-}" in
  on)
    run_systemctl enable --now
    echo -n "Servicio encendido. Esperando el túnel"
    for _ in $(seq 1 15); do
      [[ -n "$(tunnel_ip)" ]] && break
      echo -n "."
      sleep 2
    done
    echo
    if [[ -n "$(tunnel_ip)" ]]; then
      echo "✅ Conectado: IP de túnel $(tunnel_ip)."
    else
      echo "⏳ Aún sin túnel. Si la asociación está apagada, enciéndela (consola de AWS o vpn-hub.sh):"
      echo "   el servicio reintenta solo y conecta unos minutos después."
    fi
    show_status
    ;;
  off)
    run_systemctl disable --now
    echo "✅ Servicio detenido y sin arranque automático."
    echo "   Si ya ningún equipo usa la VPN, apaga la asociación (consola de AWS o vpn-hub.sh)."
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    echo "Uso: $0 on|off|status" >&2
    exit 2
    ;;
esac

