
#!/usr/bin/env bash
# =============================================================================
# verify-clean.sh · ¿La cuenta está libre de recursos del proyecto? (T0.6, F8)
#
# Comprueba, en SOLO LECTURA, que no quede nada de vpn-hub en la cuenta:
#   1. Recursos etiquetados Project = vpn-hub en mx-central-1 (API de
#      etiquetas; cubre VPC, subnets, security groups, endpoint de Client VPN,
#      certificados de ACM, grupos de logs, Roles Anywhere, S3 y KMS). Esa API
#      sigue listando lo borrado durante minutos u horas: los recursos de EC2
#      se confirman en la propia API de EC2 antes de marcarlos como falla.
#   2. Búsquedas por nombre, porque la API de etiquetas no ve todo (IAM y
#      Route 53 son globales): endpoint vpn-hub-cvpn, VPC vpn-hub-vpc, zona
#      privada vpn.example.internal, grupo de logs /aws/clientvpn/vpn-hub,
#      trust anchor vpn-hub-ca y perfil vpn-hub-dns-updater de Roles Anywhere,
#      rol de IAM vpn-hub-dns-updater y presupuesto vpn-hub-monthly.
#   3. Estado remoto (stack bootstrap): bucket vpn-hub-tfstate-<cuenta> y alias
#      alias/vpn-hub-tfstate. La llave KMS puede seguir existiendo solo en
#      PendingDeletion (AWS espera 7 días antes de borrarla). También el bucket
#      manual del script de CloudShell, vpn-hub-prod-<cuenta>, y las CRL
#      importadas en Roles Anywhere (se borran a mano en T8.3).
#
# Opciones:
#   --except-bootstrap  no revisa el estado remoto, las CRL de Roles Anywhere
#                       ni el bucket manual del script: se usa tras destruir solo el hub (T3.6, T8.2).
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-clean.sh [--except-bootstrap]
#         tests/aws/verify-clean.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

except_bootstrap=false
case "${1:-}" in
  --help | -h) show_help; exit 0 ;;
  --except-bootstrap) except_bootstrap=true ;;
  "") ;;
  *) echo "Opción desconocida: $1 (usa --help)"; exit 2 ;;
esac

require_session
info "Perfil $PROFILE, región $REGION$($except_bootstrap && echo ', sin revisar el estado remoto')."

# Recursos del bootstrap que se permiten con --except-bootstrap.
# (Incluye el bucket manual del script de CloudShell, vpn-hub-prod-<cuenta>,
# que se borra a mano en T8.3, después de destruir el hub.)
is_bootstrap_arn() { [[ "$1" == arn:aws:s3:::"$PROJECT"-tfstate-* || "$1" == arn:aws:s3:::"$PROJECT"-prod-* || "$1" == arn:aws:kms:* ]]; }

# La API de etiquetas sigue listando recursos borrados durante un rato (minutos u
# horas). Para los de EC2 se confirma en la propia API de EC2 si aún existen.
# Regresa 0 si el recurso existe (o si no se sabe comprobar) y 1 si ya no existe.
ec2_resource_exists() {
  local arn="$1" kind id
  [[ "$arn" == arn:aws:ec2:* ]] || return 0
  kind="${arn##*:}"; id="${kind#*/}"; kind="${kind%%/*}"
  case "$kind" in
    security-group) aws_ro ec2 describe-security-groups --group-ids "$id" >/dev/null 2>&1 ;;
    security-group-rule) aws_ro ec2 describe-security-group-rules --security-group-rule-ids "$id" >/dev/null 2>&1 ;;
    vpc) aws_ro ec2 describe-vpcs --vpc-ids "$id" >/dev/null 2>&1 ;;
    subnet) aws_ro ec2 describe-subnets --subnet-ids "$id" >/dev/null 2>&1 ;;
    client-vpn-endpoint) aws_ro ec2 describe-client-vpn-endpoints --client-vpn-endpoint-ids "$id" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# 1. API de etiquetas.
tagged="$(aws_ro resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed '/^$/d')"
leftovers=0
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  if [[ "$arn" == arn:aws:kms:* ]]; then
    # Una llave KMS en PendingDeletion es lo esperado tras un destroy.
    state="$(aws_ro kms describe-key --key-id "$arn" --query KeyMetadata.KeyState --output text 2>/dev/null || echo "NotFound")"
    if [[ "$state" == "PendingDeletion" || "$state" == "NotFound" ]]; then
      info "llave KMS del proyecto en $state (se borra sola)"
      continue
    fi
  fi
  if $except_bootstrap && is_bootstrap_arn "$arn"; then
    info "se conserva (bootstrap): $arn"
    continue
  fi
  if ! ec2_resource_exists "$arn"; then
    info "ya borrado (la API de etiquetas aún lo lista): $arn"
    continue
  fi
  fail "recurso etiquetado Project=$PROJECT: $arn"
  leftovers=$((leftovers + 1))
done <<<"$tagged"
if (( leftovers == 0 )); then
  ok "sin recursos etiquetados Project=$PROJECT en $REGION (salvo los permitidos)"
fi

# 2. Búsquedas por nombre.
# Uso: expect_empty "<descripción>" <comando aws_ro que imprime lo encontrado>
expect_empty() {
  local label="$1" found; shift
  if ! found="$("$@" 2>&1)"; then
    fail "no se pudo revisar $label: $(grep -m1 . <<<"$found")"
    return
  fi
  found="$(sed -e '/^None$/d' -e '/^[[:space:]]*$/d' <<<"$found")"
  if [[ -z "$found" ]]; then
    ok "no existe $label"
  else
    fail "existe $label: $(tr '\n' ' ' <<<"$found")"
  fi
}

expect_empty "el endpoint de Client VPN ${PROJECT}-cvpn" \
  aws_ro ec2 describe-client-vpn-endpoints \
  --query "ClientVpnEndpoints[?Tags[?Key=='Name' && Value=='${PROJECT}-cvpn']].ClientVpnEndpointId" --output text
expect_empty "la VPC ${PROJECT}-vpc" \
  aws_ro ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-vpc" --query 'Vpcs[].VpcId' --output text
expect_empty "la zona privada $ZONE_NAME" \
  aws_ro route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
  --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" --output text
expect_empty "el grupo de logs /aws/clientvpn/$PROJECT" \
  aws_ro logs describe-log-groups --log-group-name-prefix "/aws/clientvpn/$PROJECT" \
  --query 'logGroups[].logGroupName' --output text
expect_empty "el trust anchor ${PROJECT}-ca de Roles Anywhere" \
  aws_ro rolesanywhere list-trust-anchors --query "trustAnchors[?name=='${PROJECT}-ca'].name" --output text
expect_empty "el perfil ${PROJECT}-dns-updater de Roles Anywhere" \
  aws_ro rolesanywhere list-profiles --query "profiles[?name=='${PROJECT}-dns-updater'].name" --output text
expect_empty "el rol de IAM ${PROJECT}-dns-updater" \
  aws_ro iam list-roles --query "Roles[?RoleName=='${PROJECT}-dns-updater'].RoleName" --output text
expect_empty "el presupuesto ${PROJECT}-monthly" \
  aws_ro budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query "Budgets[?BudgetName=='${PROJECT}-monthly'].BudgetName" --output text

# 3. Estado remoto.
if $except_bootstrap; then
  info "se omite el estado remoto (--except-bootstrap)."
else
  bucket="${PROJECT}-tfstate-${ACCOUNT_ID}"
  if aws_ro s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    fail "existe el bucket del estado $bucket"
  else
    ok "no existe el bucket del estado ${PROJECT}-tfstate-<cuenta>"
  fi
  expect_empty "el alias KMS alias/${PROJECT}-tfstate" \
    aws_ro kms list-aliases --query "Aliases[?AliasName=='alias/${PROJECT}-tfstate'].AliasName" --output text
  # CRL importadas en Roles Anywhere (solo si se revocó un equipo de la LAN; T8.3).
  expect_empty "una CRL importada en Roles Anywhere" \
    aws_ro rolesanywhere list-crls --query "crls[].name" --output text
  # Bucket manual del script de CloudShell (T7.5): se borra a mano en T8.3.
  script_bucket="${PROJECT}-prod-${ACCOUNT_ID}"
  if aws_ro s3api head-bucket --bucket "$script_bucket" >/dev/null 2>&1; then
    fail "existe el bucket manual del script ${script_bucket} (bórralo, ver terraform/README)"
  else
    ok "no existe el bucket manual del script ${PROJECT}-prod-<cuenta>"
  fi
fi

finish

