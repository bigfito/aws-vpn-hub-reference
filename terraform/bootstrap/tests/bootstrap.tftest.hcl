
# =============================================================================
# bootstrap.tftest.hcl · Pruebas unitarias del stack bootstrap (terraform test)
#
# Comprueban que el bucket del estado remoto y su llave KMS sean seguros y se
# puedan destruir (docs/design-decisions.md), SIN tocar
# AWS: los proveedores aws y local son simulados (mock_provider), así que no
# hacen falta credenciales ni se escribe terraform/hub/backend.hcl.
#
# Cómo se ejecuta (desde la raíz del repositorio):
#   terraform -chdir=terraform/bootstrap test
# (Si el stack nunca se inicializó, antes: terraform -chdir=terraform/bootstrap
# init -backend=false.)
#
# Si un caso usa "expect_failures", lo correcto es que esa validación FALLE.
# Los IDs de cuenta de aquí (111111111111 y 999999999999) son ficticios.
# =============================================================================

# Proveedor de AWS simulado con una cuenta miembro ficticia cuya cuenta de
# administración es otra (el candado de cuenta deja pasar el plan).
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }

  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "999999999999" }
  }

  # JSON válido para la política del bucket (si no, sería texto al azar).
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

# El archivo backend.hcl del hub se simula: la prueba no lo escribe.
mock_provider "local" {}

# Variables obligatorias para todos los casos (las demás usan su default).
variables {
  owner               = "pruebas"
  expected_account_id = "111111111111"
}

# Destrucción: el bucket se borra aunque tenga versiones del estado y la llave
# KMS se elimina tras la espera mínima de 7 días.
run "destruible" {
  command = plan

  assert {
    condition     = aws_s3_bucket.terraform_state.force_destroy == true
    error_message = "El bucket del estado debe tener force_destroy = true."
  }

  assert {
    condition     = aws_kms_key.terraform_state.deletion_window_in_days == 7
    error_message = "kms_deletion_window_days debe ser 7 (la espera mínima de AWS)."
  }

  assert {
    condition     = aws_s3_bucket.terraform_state.bucket == "vpn-hub-tfstate-111111111111"
    error_message = "El bucket debe llamarse vpn-hub-tfstate-<cuenta>."
  }
}

# Seguridad: versionado, cifrado con KMS y bloqueo total de acceso público.
run "seguro" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.terraform_state.versioning_configuration[0].status == "Enabled"
    error_message = "El versionado del bucket debe estar en Enabled."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.terraform_state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "El cifrado del bucket debe ser SSE-KMS (aws:kms)."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.terraform_state.block_public_acls == true &&
      aws_s3_bucket_public_access_block.terraform_state.block_public_policy == true &&
      aws_s3_bucket_public_access_block.terraform_state.ignore_public_acls == true &&
      aws_s3_bucket_public_access_block.terraform_state.restrict_public_buckets == true
    )
    error_message = "Las 4 banderas del bloqueo de acceso público deben estar en true."
  }

  assert {
    condition     = aws_kms_key.terraform_state.enable_key_rotation == true
    error_message = "La llave KMS debe rotar automáticamente."
  }

  assert {
    condition     = data.aws_iam_policy_document.tls_only.statement[0].effect == "Deny" && toset(one(data.aws_iam_policy_document.tls_only.statement[0].condition).values) == toset(["false"])
    error_message = "La política del bucket debe negar todo acceso sin TLS (aws:SecureTransport = false)."
  }
}

# Candado de cuenta: en la cuenta miembro el plan pasa.
run "cuenta_miembro_pasa" {
  command = plan

  assert {
    condition     = data.aws_organizations_organization.current.master_account_id != data.aws_caller_identity.current.account_id
    error_message = "Con la cuenta de administración distinta de la actual, el plan debe pasar."
  }
}

# Candado de cuenta: con credenciales de la cuenta de administración, la
# postcondición detiene el plan.
run "cuenta_de_administracion_falla" {
  command = plan

  override_data {
    target = data.aws_organizations_organization.current
    values = { master_account_id = "111111111111" }
  }

  expect_failures = [data.aws_organizations_organization.current]
}

# Un ID de cuenta que no tiene 12 dígitos no pasa la validación.
run "id_de_cuenta_invalido_falla" {
  command = plan

  variables {
    expected_account_id = "123"
  }

  expect_failures = [var.expected_account_id]
}

# El archivo backend.hcl del hub usa el bucket, el cifrado y el bloqueo nativo
# de S3 (use_lockfile). Su contenido depende del ID del bucket, que solo se
# conoce al aplicar: por eso este caso usa "apply", contra los proveedores
# simulados (no crea nada en AWS ni escribe el archivo). Va al final para que
# los demás casos partan de un estado vacío.
run "configuracion_del_backend_del_hub" {
  command = apply

  assert {
    condition     = endswith(local_file.hub_backend_config.filename, "../hub/backend.hcl")
    error_message = "El bootstrap debe escribir terraform/hub/backend.hcl."
  }

  assert {
    condition = (
      strcontains(local_file.hub_backend_config.content, "bucket       = \"${aws_s3_bucket.terraform_state.id}\"") &&
      strcontains(local_file.hub_backend_config.content, "encrypt      = true") &&
      strcontains(local_file.hub_backend_config.content, "use_lockfile = true")
    )
    error_message = "backend.hcl debe apuntar al bucket del estado, con cifrado y use_lockfile."
  }
}

