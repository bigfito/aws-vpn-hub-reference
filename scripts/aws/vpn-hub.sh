
#!/usr/bin/env bash
# =============================================================================
# vpn-hub.sh · Enciende y apaga la VPN de vpn-hub desde AWS CloudShell
#
# Reemplaza los clics de la consola para la asociación del endpoint de Client
# VPN (lo que AWS cobra por hora) y la ruta cliente-a-cliente:
#
#   --enable    Asocia la subnet del hub al endpoint, espera a que el endpoint
#               esté "available", crea la ruta 10.81.0.0/22 -> local (se borra
#               cada vez que se desasocia) y espera a que quede activa.
#   --disable   Muestra las conexiones activas, pide confirmación (salvo con
#               --yes) y desasocia el endpoint. AWS corta todas las conexiones.
#   --status    Solo lectura: asociación, rutas, conexiones activas y nombres
#               DNS de la zona privada.
#
# Modificadores:
#   --dry-run   Con --enable o --disable: AWS comprueba los permisos de cada
#               paso (DryRun) sin cambiar nada.
#   --yes       Con --disable: no pide confirmación.
#
# Cómo se usa en CloudShell (CloudShell no existe en mx-central-1: abre la
# consola en us-east-2; el script siempre trabaja en mx-central-1):
#   aws s3 cp s3://vpn-hub-prod-<cuenta>/vpn-hub.sh . --region mx-central-1
#   bash vpn-hub.sh --status
#   bash vpn-hub.sh --enable
#   bash vpn-hub.sh --disable
#
# Variables opcionales: VPN_HUB_REGION (por defecto mx-central-1) y
# VPN_HUB_POLL_SECONDS (espera entre consultas, por defecto 15).
# El endpoint y la subnet se buscan por su etiqueta Name (vpn-hub-cvpn y
# vpn-hub-cvpn-<az>): no hay IDs escritos aquí, así que sigue funcionando si el
# hub se vuelve a crear con Terraform.
#
# Salida: 0 si todo salió bien, 1 si algo falló, 2 si las opciones son
# incorrectas. Los equipos de la LAN se encienden y apagan aparte, con
# vpn-hub-service on|off en cada uno.
# =============================================================================
set -euo pipefail

REGION="${VPN_HUB_REGION:-mx-central-1}"
POLL_SECONDS="${VPN_HUB_POLL_SECONDS:-15}"
ENDPOINT_NAME="vpn-hub-cvpn"
ZONE_NAME="vpn.example.internal"
ENABLE_TIMEOUT_SECONDS=1200   # la asociación suele tardar entre 5 y 15 minutos
DISABLE_TIMEOUT_SECONDS=900

usage() {
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
}

# --- Opciones ---------------------------------------------------------------------
action=""
dry_run=false
assume_yes=false
while (( $# > 0 )); do
  case "$1" in
    --enable | --disable | --status)
      if [[ -n "$action" ]]; then echo "Usa solo una de --enable, --disable o --status." >&2; exit 2; fi
      action="${1#--}" ;;
    --dry-run) dry_run=true ;;
    --yes | -y) assume_yes=true ;;
    --help | -h) usage; exit 0 ;;
    *) echo "Opción desconocida: $1 (usa --help)" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z "$action" ]]; then usage; exit 2; fi
if $dry_run && [[ "$action" == "status" ]]; then
  echo "--dry-run solo aplica a --enable y --disable (--status ya es de solo lectura)." >&2
  exit 2
fi

# --- AWS CLI ----------------------------------------------------------------------
# Toda llamada va a la región del proyecto, aunque CloudShell corra en otra.
aws_text() { aws "$@" --region "$REGION" --output text; }

# Ejecuta una operación que cambia algo. Con --dry-run agrega --dry-run y trata
# la respuesta "DryRunOperation" (que AWS devuelve como error) como éxito.
aws_change() {
  local label="$1" output
  shift
  if $dry_run; then
    if output="$(aws "$@" --region "$REGION" --dry-run 2>&1)"; then
      echo "   🧪 $label: AWS lo aceptó sin DryRun (revisa)"; return 0
    fi
    if grep -q "DryRunOperation" <<<"$output"; then
      echo "   🧪 $label: tienes permiso (DryRun, no se cambió nada)"; return 0
    fi
    echo "   ❌ $label: $(grep -m1 . <<<"$output")" >&2; return 1
  fi
  if ! output="$(aws "$@" --region "$REGION" --output text 2>&1)"; then
    echo "   ❌ $label: $(grep -m1 . <<<"$output")" >&2; return 1
  fi
  echo "   ✅ $label"
}

# --- Lecturas -----------------------------------------------------------------------
# Endpoint: ID, estado, VPC y rango de clientes (una línea separada por tabuladores).
read_endpoint() {
  local line
  line="$(aws_text ec2 describe-client-vpn-endpoints \
    --query "ClientVpnEndpoints[?Tags[?Key=='Name' && Value=='${ENDPOINT_NAME}']] | [0].[ClientVpnEndpointId,Status.Code,VpcId,ClientCidrBlock]")"
  IFS=$'\t' read -r endpoint_id endpoint_status vpc_id client_cidr <<<"$line"
  if [[ -z "${endpoint_id:-}" || "$endpoint_id" == "None" ]]; then
    echo "❌ No existe el endpoint ${ENDPOINT_NAME} en ${REGION}. ¿Está desplegado el hub (Terraform)?" >&2
    exit 1
  fi
}

# Asociaciones vigentes: "<asociación> <subnet> <estado>" por línea.
read_associations() {
  aws_text ec2 describe-client-vpn-target-networks --client-vpn-endpoint-id "$endpoint_id" \
    --query "ClientVpnTargetNetworks[?Status.Code!='disassociated'].[AssociationId,TargetNetworkId,Status.Code]" |
    sed '/^[[:space:]]*$/d'
}

# Rutas: "<destino> <subred o local> <estado>" por línea.
read_routes() {
  aws_text ec2 describe-client-vpn-routes --client-vpn-endpoint-id "$endpoint_id" \
    --query "Routes[].[DestinationCidr,TargetSubnet,Status.Code]" | sed '/^[[:space:]]*$/d'
}

# Conexiones activas: "<CN> <IP de túnel>" por línea.
read_connections() {
  aws_text ec2 describe-client-vpn-connections --client-vpn-endpoint-id "$endpoint_id" \
    --query "Connections[?Status.Code=='active'].[CommonName,ClientIp]" | sed '/^[[:space:]]*$/d'
}

# Subnets del hub que se asocian (vpn-hub-cvpn-<az>; dos con alta disponibilidad).
read_hub_subnets() {
  aws_text ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${ENDPOINT_NAME}-*" \
    --query "Subnets[].SubnetId" | tr '\t' '\n' | sed '/^[[:space:]]*$/d'
}

show_status() {
  local associations routes connections zone_id records
  echo "🔎 Endpoint ${ENDPOINT_NAME} (${endpoint_id}) en ${REGION}: ${endpoint_status}"
  associations="$(read_associations)"
  if [[ -z "$associations" ]]; then
    echo "   Asociación: APAGADA (no se cobra por hora)"
  else
    while read -r assoc subnet state; do echo "   Asociación: ${subnet} → ${state} (${assoc}) — se cobra por hora"; done <<<"$associations"
  fi
  routes="$(read_routes)"
  if [[ -z "$routes" ]]; then
    echo "   Rutas: ninguna"
  else
    while read -r dest target state; do echo "   Ruta: ${dest} → ${target} (${state})"; done <<<"$routes"
  fi
  connections="$(read_connections)"
  if [[ -z "$connections" ]]; then
    echo "   Conexiones activas: ninguna"
  else
    while read -r cn ip; do echo "   Conexión activa: ${cn} (${ip})"; done <<<"$connections"
    if [[ -z "$associations" ]]; then
      echo "   ℹ️  Sin asociación, AWS puede seguir listando conexiones ya cortadas hasta volver a asociar."
    fi
  fi
  zone_id="$(aws_text route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[?Name=='${ZONE_NAME}.'] | [0].Id" | sed -e 's#^/hostedzone/##' -e 's/^None$//')"
  if [[ -n "$zone_id" ]]; then
    records="$(aws_text route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --query "ResourceRecordSets[?Type=='A'].[Name,ResourceRecords[0].Value]" | sed '/^[[:space:]]*$/d')"
    while read -r name value; do
      [[ -n "${name:-}" ]] && echo "   DNS: ${name%.} → ${value}"
    done <<<"$records"
  fi
}

# Espera hasta que el comando de la condición regrese 0, o falla al vencer el plazo.
wait_for() {
  local label="$1" timeout="$2" waited=0
  shift 2
  echo "   ⏳ Esperando: $label (hasta $((timeout / 60)) min)"
  until "$@"; do
    if (( waited >= timeout )); then
      echo "   ❌ Se venció el plazo esperando: $label. Revisa con: bash $0 --status" >&2
      return 1
    fi
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

endpoint_is() { read_endpoint; [[ "$endpoint_status" == "$1" ]]; }
local_route_active() { read_routes | awk -v c="$client_cidr" '$1 == c && $3 == "active" { found = 1 } END { exit !found }'; }
no_associations() { [[ -z "$(read_associations)" ]]; }

# --- Acciones -----------------------------------------------------------------------
do_enable() {
  local subnets associated subnet
  echo "🟢 Encendiendo la VPN$($dry_run && echo ' (DRY-RUN: no se cambia nada)')"
  subnets="$(read_hub_subnets)"
  if [[ -z "$subnets" ]]; then
    echo "❌ No se encontraron subnets ${ENDPOINT_NAME}-* en la VPC del hub." >&2
    exit 1
  fi
  associated="$(read_associations | awk '{ print $2 }')"
  for subnet in $subnets; do
    if grep -qx "$subnet" <<<"$associated"; then
      echo "   ✔️  ${subnet} ya está asociada"
    else
      aws_change "asociar ${subnet}" ec2 associate-client-vpn-target-network \
        --client-vpn-endpoint-id "$endpoint_id" --subnet-id "$subnet"
    fi
  done

  if ! $dry_run; then
    wait_for "endpoint available" "$ENABLE_TIMEOUT_SECONDS" endpoint_is available
  fi

  if read_routes | awk -v c="$client_cidr" '$1 == c { found = 1 } END { exit !found }'; then
    echo "   ✔️  la ruta ${client_cidr} → local ya existe"
  else
    aws_change "crear la ruta ${client_cidr} → local" ec2 create-client-vpn-route \
      --client-vpn-endpoint-id "$endpoint_id" --destination-cidr-block "$client_cidr" \
      --target-vpc-subnet-id local --description "Cliente a cliente (vpn-hub.sh)"
  fi

  if $dry_run; then
    echo "🧪 DRY-RUN terminado: no se cambió nada."
    return 0
  fi
  wait_for "ruta ${client_cidr} → local activa" "$ENABLE_TIMEOUT_SECONDS" local_route_active
  echo "✅ VPN encendida. 💰 Se cobra por hora mientras esté asociada."
  echo "   Siguiente: vpn-hub-service on en los equipos de la LAN que quieras usar."
  show_status
}

do_disable() {
  local associations connections answer assoc
  echo "🔴 Apagando la VPN$($dry_run && echo ' (DRY-RUN: no se cambia nada)')"
  associations="$(read_associations)"
  if [[ -z "$associations" ]]; then
    echo "   ✔️  ya está apagada (sin asociación)"
    return 0
  fi
  connections="$(read_connections)"
  if [[ -n "$connections" ]]; then
    echo "   ⚠️  Conexiones activas que se cortarán:"
    while read -r cn ip; do echo "      - ${cn} (${ip})"; done <<<"$connections"
  fi
  if ! $dry_run && ! $assume_yes; then
    if [[ ! -t 0 ]]; then
      echo "❌ Sin terminal para confirmar. Repite con --yes si de verdad quieres apagar." >&2
      exit 1
    fi
    read -r -p "   ¿Desasociar el endpoint? [s/N] " answer
    if [[ ! "$answer" =~ ^[sSyY]$ ]]; then
      echo "   Cancelado: no se cambió nada."
      return 0
    fi
  fi
  while read -r assoc _ _; do
    aws_change "desasociar ${assoc}" ec2 disassociate-client-vpn-target-network \
      --client-vpn-endpoint-id "$endpoint_id" --association-id "$assoc"
  done <<<"$associations"

  if $dry_run; then
    echo "🧪 DRY-RUN terminado: no se cambió nada."
    return 0
  fi
  wait_for "sin asociación" "$DISABLE_TIMEOUT_SECONDS" no_associations
  echo "✅ VPN apagada: el endpoint queda en pending-associate y sin rutas."
  echo "   Recuerda: vpn-hub-service off en los equipos de la LAN que encendiste."
  echo "   ℹ️  AWS puede seguir listando las conexiones cortadas hasta la próxima asociación."
}

# --- Principal ---------------------------------------------------------------------
read_endpoint
case "$action" in
  enable) do_enable ;;
  disable) do_disable ;;
  status) show_status ;;
esac

