
#!/usr/bin/env bash
# =============================================================================
# verify-account.sh · ¿La cuenta de AWS está lista para el proyecto? (T0.2, T0.3)
#
# Comprueba, en SOLO LECTURA:
#   1. La identidad es un rol de IAM Identity Center (SSO), no root ni un
#      usuario de IAM con llaves estáticas.
#   2. La cuenta NO es la de administración de AWS Organizations.
#   3. Si existe terraform/hub/terraform.tfvars, la cuenta coincide con
#      expected_account_id (el ID no se muestra).
#   4. La región mx-central-1 está habilitada (es opt-in).
#   5. Hay zonas de disponibilidad disponibles en mx-central-1.
#   6. Las APIs que usa el proyecto responden: Client VPN (EC2), IAM Roles
#      Anywhere, ACM, Route 53, CloudWatch Logs, S3 y KMS. Un AccessDenied aquí
#      suele ser una SCP (riesgo R10).
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-account.sh
#         tests/aws/verify-account.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then show_help; exit 0; fi

require_session
info "Perfil $PROFILE, región $REGION."

# 1. Identidad SSO.
arn="$(aws_ro sts get-caller-identity --query Arn --output text)"
if [[ "$arn" == *":assumed-role/AWSReservedSSO_"* ]]; then
  ok "identidad de IAM Identity Center (rol ${arn#*:assumed-role/})"
else
  fail "la identidad no es de IAM Identity Center: $arn. Usa el perfil SSO vpn-hub"
fi

# 2. No es la cuenta de administración.
master_id="$(aws_ro organizations describe-organization --query Organization.MasterAccountId --output text 2>/dev/null || true)"
if [[ -z "$master_id" ]]; then
  fail "no se pudo leer la organización (organizations:DescribeOrganization); no se puede confirmar que no sea la cuenta de administración"
elif [[ "$master_id" == "$ACCOUNT_ID" ]]; then
  fail "estas credenciales son de la CUENTA DE ADMINISTRACIÓN; el proyecto vive en la cuenta miembro (README)"
else
  ok "la cuenta es miembro de la organización, no la de administración"
fi

# 3. Coincide con expected_account_id de terraform.tfvars (si ya existe).
tfvars="$REPO_ROOT/terraform/hub/terraform.tfvars"
if [[ -f "$tfvars" ]]; then
  expected="$(sed -nE 's/^[[:space:]]*expected_account_id[[:space:]]*=[[:space:]]*"([0-9]+)".*/\1/p' "$tfvars" | head -1)"
  if [[ "$expected" == "$ACCOUNT_ID" ]]; then
    ok "la cuenta coincide con expected_account_id de terraform/hub/terraform.tfvars"
  else
    fail "la cuenta NO coincide con expected_account_id de terraform/hub/terraform.tfvars"
  fi
else
  info "terraform/hub/terraform.tfvars aún no existe (T3.1); se omite la comparación con expected_account_id."
fi

# 4. Región opt-in habilitada.
region_status="$(aws_ro account get-region-opt-status --region-name "$REGION" --query RegionOptStatus --output text 2>/dev/null || echo "ERROR")"
case "$region_status" in
  ENABLED | ENABLED_BY_DEFAULT) ok "región $REGION habilitada ($region_status)" ;;
  *) fail "región $REGION no habilitada (estado: $region_status). Habilítala desde la cuenta de administración" ;;
esac

# 5. Zonas de disponibilidad.
azs="$(aws_ro ec2 describe-availability-zones --filters Name=state,Values=available --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null || true)"
az_count="$(wc -w <<<"$azs")"
if (( az_count >= 1 )); then
  ok "$az_count zona(s) de disponibilidad: $azs"
else
  fail "no hay zonas de disponibilidad disponibles en $REGION"
fi
if (( az_count < 2 )); then
  warn "con menos de 2 AZ no se puede usar enable_high_availability = true"
fi

# 6. APIs del proyecto: cada llamada solo lista y se descarta la respuesta.
check_api() {
  local label="$1"; shift
  local output
  if output="$(aws_ro "$@" 2>&1 >/dev/null)"; then
    ok "API de $label responde"
  elif grep -q "service control policy" <<<"$output"; then
    fail "API de $label bloqueada por una SCP (riesgo R10): $(grep -m1 . <<<"$output")"
  else
    fail "API de $label no responde: $(grep -m1 . <<<"$output")"
  fi
}
check_api "Client VPN" ec2 describe-client-vpn-endpoints --max-results 5
check_api "IAM Roles Anywhere" rolesanywhere list-trust-anchors
check_api "ACM" acm list-certificates --max-items 1
check_api "Route 53" route53 list-hosted-zones --max-items 1
check_api "CloudWatch Logs" logs describe-log-groups --limit 1
check_api "S3" s3api list-buckets --max-items 1
check_api "KMS" kms list-aliases --limit 1

finish

