
#!/usr/bin/env bash
# =============================================================================
# verify-bootstrap.sh · ¿El estado remoto quedó bien creado? (T2.3)
#
# Comprueba, en SOLO LECTURA, el bucket vpn-hub-tfstate-<cuenta> y su llave KMS
# (stack terraform/bootstrap):
#   1. El bucket existe.
#   2. Versionado Enabled (se puede recuperar un estado anterior).
#   3. Cifrado por defecto SSE-KMS con la llave alias/vpn-hub-tfstate.
#   4. Bloqueo de acceso público con las 4 banderas en true.
#   5. La política del bucket niega el acceso sin TLS (aws:SecureTransport).
#   6. La llave KMS está habilitada y con rotación automática.
#   7. Existe terraform/hub/backend.hcl, apunta al bucket y usa use_lockfile.
#
# Uso:    AWS_PROFILE=vpn-hub tests/aws/verify-bootstrap.sh
#         tests/aws/verify-bootstrap.sh --help
# Salida: "✅ OK:" o "❌ FALLA:" por verificación; código 0 si todo pasa y 1 si
#         algo falla. Nunca crea, cambia ni borra nada; no muestra IDs de cuenta.
# =============================================================================
set -euo pipefail
# shellcheck source=tests/aws/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then show_help; exit 0; fi

require_session
bucket="${PROJECT}-tfstate-${ACCOUNT_ID}"
alias_name="alias/${PROJECT}-tfstate"
info "Perfil $PROFILE, región $REGION, bucket $bucket."

# 1. El bucket existe; sin él no tiene caso seguir.
if ! aws_ro s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  fail "no existe el bucket $bucket. ¿Ya se aplicó el bootstrap (T2.3)?"
  finish
fi
ok "existe el bucket $bucket"

# 2. Versionado.
versioning="$(aws_ro s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)"
if [[ "$versioning" == "Enabled" ]]; then ok "versionado Enabled"; else fail "versionado en '$versioning' (debe ser Enabled)"; fi

# 3. Cifrado SSE-KMS con la llave del proyecto.
key_arn="$(aws_ro kms describe-key --key-id "$alias_name" --query KeyMetadata.Arn --output text 2>/dev/null || true)"
read -r sse_algorithm sse_key <<<"$(aws_ro s3api get-bucket-encryption --bucket "$bucket" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm,KMSMasterKeyID]' --output text)"
if [[ "$sse_algorithm" == "aws:kms" && -n "$key_arn" && "$sse_key" == "$key_arn" ]]; then
  ok "cifrado SSE-KMS con la llave $alias_name"
else
  fail "cifrado '$sse_algorithm' con llave '$sse_key' (debe ser aws:kms con $alias_name)"
fi

# 4. Bloqueo de acceso público.
flags="$(aws_ro s3api get-public-access-block --bucket "$bucket" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text)"
if [[ "$(tr -s '[:space:]' ' ' <<<"$flags" | xargs)" == "True True True True" ]]; then
  ok "bloqueo de acceso público con las 4 banderas en true"
else
  fail "bloqueo de acceso público incompleto: $flags"
fi

# 5. Política solo-TLS.
policy="$(aws_ro s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>/dev/null || true)"
if grep -q '"aws:SecureTransport"' <<<"$policy" && grep -q '"Deny"' <<<"$policy"; then
  ok "la política del bucket niega el acceso sin TLS"
else
  fail "la política del bucket no niega el acceso sin TLS (aws:SecureTransport)"
fi

# 6. Llave KMS habilitada y con rotación.
if [[ -z "$key_arn" ]]; then
  fail "no existe la llave $alias_name"
else
  key_state="$(aws_ro kms describe-key --key-id "$alias_name" --query KeyMetadata.KeyState --output text)"
  rotation="$(aws_ro kms get-key-rotation-status --key-id "$key_arn" --query KeyRotationEnabled --output text)"
  if [[ "$key_state" == "Enabled" && "$rotation" == "True" ]]; then
    ok "llave $alias_name habilitada y con rotación automática"
  else
    fail "llave $alias_name en estado $key_state, rotación $rotation (debe ser Enabled y True)"
  fi
fi

# 7. backend.hcl del hub (archivo local que escribe el bootstrap).
backend="$REPO_ROOT/terraform/hub/backend.hcl"
if [[ ! -f "$backend" ]]; then
  fail "no existe terraform/hub/backend.hcl (lo escribe el apply del bootstrap)"
elif grep -q "bucket *= *\"$bucket\"" "$backend" && grep -q 'use_lockfile *= *true' "$backend" && grep -q 'encrypt *= *true' "$backend"; then
  ok "terraform/hub/backend.hcl apunta al bucket, con cifrado y use_lockfile"
else
  fail "terraform/hub/backend.hcl no apunta a $bucket o le falta encrypt/use_lockfile"
fi

finish

