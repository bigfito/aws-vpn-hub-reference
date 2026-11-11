
#!/usr/bin/env bash
# Las constantes de abajo las usan los scripts que cargan este archivo:
# shellcheck disable=SC2034
# =============================================================================
# lib.sh · Funciones comunes de las pruebas de AWS (tests/aws/verify-*.sh)
#
# No se ejecuta sola: cada prueba la carga con "source". Ofrece:
#   aws_ro        la AWS CLI en SOLO LECTURA: región mx-central-1 y perfil
#                 explícitos, y se niega a ejecutar cualquier operación que no
#                 empiece con describe-, list-, get- o head- (README: las
#                 pruebas nunca crean, cambian ni borran nada).
#   ok, fail,     una línea "✅ OK:", "❌ FALLA:", "ℹ️" o "⚠️" por verificación;
#   info, warn    fail cuenta los errores.
#   finish        imprime el resultado y sale con 0 (todo pasó) o 1.
#   mask          oculta los IDs de cuenta (12 dígitos) en la salida: nunca se
#                 muestran en la bitácora ni en la conversación.
#   require_session  comprueba que haya sesión SSO antes de empezar.
#   show_help     imprime el encabezado del script como ayuda (--help).
#
# Variables: AWS_PROFILE (por defecto vpn-hub) y AWS_REGION_HUB (por defecto
# mx-central-1).
# =============================================================================

# Valores del proyecto (los mismos que el código Terraform).
REGION="${AWS_REGION_HUB:-mx-central-1}"
PROFILE="${AWS_PROFILE:-vpn-hub}"
PROJECT="vpn-hub"
ZONE_NAME="vpn.example.internal"
VPC_CIDR="10.80.0.0/16"
VPN_CLIENT_CIDR="10.81.0.0/22"
VPC_DNS_SERVER="10.80.0.2"
HOME_DEVICES=(workstation-2 workstation-1)
ALL_DEVICES=(workstation-2 workstation-1 tablet-1)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

failures=0
checks=0

ok()   { checks=$((checks + 1)); echo "✅ OK: $(mask "$*")"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "❌ FALLA: $(mask "$*")"; }
info() { echo "ℹ️  $(mask "$*")"; }
warn() { echo "⚠️  $(mask "$*")"; }

# Reemplaza cualquier número de 12 dígitos (ID de cuenta) por <cuenta>.
mask() { sed -E 's/[0-9]{12}/<cuenta>/g' <<<"$*"; }

# Imprime el encabezado del script que llamó (las líneas "# " entre las dos
# primeras líneas "# ====").
show_help() {
  awk '/^# =+$/ { n++; next } n == 1 { sub(/^# ?/, ""); print } n >= 2 { exit }' "$0"
}

# AWS CLI de solo lectura. Uso: aws_ro <servicio> <operación> [opciones...]
# Salida en texto sin "\r" (la AWS CLI de Windows termina las líneas con CRLF).
aws_ro() {
  local service="$1" operation="$2"
  if [[ ! "$operation" =~ ^(describe|list|get|head)- ]]; then
    echo "❌ FALLA: operación no permitida en una prueba de solo lectura: aws $service $operation" >&2
    exit 2
  fi
  shift 2
  # MSYS_NO_PATHCONV=1: en Git Bash de Windows evita que "/aws/clientvpn/..." se
  # convierta en una ruta de Windows (en Linux no tiene efecto).
  MSYS_NO_PATHCONV=1 aws "$service" "$operation" --region "$REGION" --profile "$PROFILE" "$@" | tr -d '\r'
}

# Detiene la prueba si no hay sesión de AWS válida (por ejemplo, SSO vencido).
require_session() {
  local arn
  if ! arn="$(aws_ro sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    echo "❌ FALLA: no hay sesión de AWS con el perfil $PROFILE. Ejecuta: aws sso login --profile $PROFILE"
    exit 1
  fi
  if [[ "$arn" == *":root" ]]; then
    echo "❌ FALLA: las credenciales son del usuario root. Usa el perfil SSO vpn-hub (README)."
    exit 1
  fi
  ACCOUNT_ID="$(aws_ro sts get-caller-identity --query Account --output text)"
  export ACCOUNT_ID
}

# Termina la prueba: resumen y código de salida.
finish() {
  if (( failures > 0 )); then
    echo "Resultado: FALLA — $failures de $checks verificación(es) con error."
    exit 1
  fi
  echo "Resultado: PASA — $checks verificación(es) correctas."
  exit 0
}

# ID del endpoint de Client VPN del proyecto (etiqueta Name = vpn-hub-cvpn), o
# vacío si no existe.
find_endpoint_id() {
  aws_ro ec2 describe-client-vpn-endpoints \
    --query "ClientVpnEndpoints[?Tags[?Key=='Name' && Value=='${PROJECT}-cvpn']].ClientVpnEndpointId | [0]" \
    --output text | sed 's/^None$//'
}

# ID de la zona privada del proyecto (sin el prefijo /hostedzone/), o vacío.
find_zone_id() {
  aws_ro route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[?Name=='${ZONE_NAME}.' && Config.PrivateZone] | [0].Id" \
    --output text | sed -e 's/^None$//' -e 's#^/hostedzone/##'
}

