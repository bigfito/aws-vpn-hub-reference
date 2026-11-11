
# =============================================================================
# main.tf · Estado remoto de Terraform: bucket S3 + llave KMS (stack bootstrap)
#
# ¿Qué es el "estado"? Terraform guarda en un archivo (el estado) qué recursos
# creó y con qué valores. El stack "hub" guarda ahí, además, las llaves privadas
# de la CA y de los dispositivos (certificates.tf). Por eso su estado NO puede
# vivir en tu disco ni en git: vive en este bucket S3, cifrado con una llave
# KMS propia, versionado y accesible solo por HTTPS.
#
# Este stack usa estado local: es pequeño y no contiene secretos. Al final
# escribe ../hub/backend.hcl para que el hub sepa dónde guardar su estado.
# Para borrar todo, primero se destruye el hub y después este stack.
# =============================================================================

# Identidad de quien ejecuta Terraform (cuenta y ARN). Solo lectura. Se usa
# para el nombre del bucket y en el candado de cuenta (account_guard.tf).
data "aws_caller_identity" "current" {}

# Valores calculados que se usan en varios bloques.
locals {
  # Los nombres de bucket S3 son únicos en TODO AWS; agregar el ID de la cuenta
  # evita choques con buckets de otras personas. Ejemplo: vpn-hub-tfstate-<cuenta>.
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# Llave KMS administrada por nosotros (no la de AWS por defecto), para controlar
# quién puede descifrar el estado y poder borrarla al retirar el proyecto.
resource "aws_kms_key" "terraform_state" {
  description = "Cifrado del estado de Terraform de ${var.project_name}"
  # KMS no borra llaves al instante: destroy las deja programadas para borrarse
  # al terminar esta ventana (mínimo 7 días), por si fue un error.
  deletion_window_in_days = var.kms_deletion_window_days
  # Rotación anual automática del material de la llave (buena práctica de AWS).
  enable_key_rotation = true
}

# Alias legible de la llave (alias/vpn-hub-tfstate), para encontrarla en la
# consola de KMS sin buscar su ID.
resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.project_name}-tfstate"
  target_key_id = aws_kms_key.terraform_state.key_id
}

# El bucket donde vive el estado del stack hub.
resource "aws_s3_bucket" "terraform_state" {
  bucket = local.state_bucket_name

  # El bucket está versionado: sin force_destroy, destroy falla con BucketNotEmpty
  # mientras queden versiones del estado o archivos de bloqueo. Destruye primero
  # el stack hub (ver terraform/README.md, "Destrucción y limpieza").
  force_destroy = var.force_destroy_state_bucket
}

# Desactiva las ACL de S3: todos los objetos pertenecen a esta cuenta y el
# acceso se controla solo con políticas. Es lo que AWS recomienda hoy.
resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Bloqueo de acceso público con las 4 banderas: nadie puede hacer público el
# bucket ni sus objetos, ni por ACL ni por política, aunque lo intente.
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versionado: cada "apply" guarda una versión nueva del estado. Si un estado se
# corrompe o se borra por error, se puede recuperar una versión anterior.
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado en reposo con la llave KMS de arriba (SSE-KMS).
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    # Bucket key: S3 pide a KMS una llave por bucket en vez de una por objeto;
    # reduce llamadas a KMS (y su costo) sin perder seguridad.
    bucket_key_enabled = true
  }
}

# Limpieza automática: las versiones viejas del estado se borran después de
# noncurrent_version_retention_days, y las subidas a medias después de 7 días.
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    # Filtro vacío = la regla aplica a todos los objetos del bucket.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # AWS exige que el versionado exista antes de configurar reglas de versiones.
  depends_on = [aws_s3_bucket_versioning.terraform_state]
}

# Política que RECHAZA cualquier acceso al bucket que no use HTTPS
# (aws:SecureTransport = false). Así el estado nunca viaja sin cifrar.
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    # "*" = cualquier persona o servicio: la regla aplica a todos.
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Aplica la política anterior al bucket.
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.tls_only.json

  # Se aplica después del bloqueo público para que AWS no la evalúe a medias.
  depends_on = [aws_s3_bucket_public_access_block.terraform_state]
}

# Escribe ../hub/backend.hcl: la configuración del backend que usa el hub con
# "terraform init -backend-config=backend.hcl". Así el código del hub no tiene
# nombres de bucket ni ARNs fijos (que incluyen el ID de la cuenta).
resource "local_file" "hub_backend_config" {
  filename        = "${path.module}/../hub/backend.hcl"
  file_permission = "0644"
  # use_lockfile = true: bloqueo nativo de S3, evita que dos personas ejecuten
  # "apply" del hub al mismo tiempo.
  content = <<-EOT
    bucket       = "${aws_s3_bucket.terraform_state.id}"
    key          = "${var.project_name}/hub.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.terraform_state.arn}"
    use_lockfile = true
  EOT
}

