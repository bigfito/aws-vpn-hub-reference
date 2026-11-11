
# =============================================================================
# outputs.tf · Valores que el stack bootstrap muestra al terminar
#
# Se consultan con "terraform output" (o "terraform output -raw <nombre>").
# Ninguno es secreto: son nombres y ARNs que identifican el estado remoto.
# =============================================================================

# Nombre del bucket: útil para revisar el estado en la consola de S3.
output "state_bucket" {
  description = "Bucket S3 del estado remoto."
  value       = aws_s3_bucket.terraform_state.id
}

# ARN de la llave KMS. Anótalo antes de destruir este stack: sirve para
# comprobar después que la llave quedó en PendingDeletion (terraform/README.md).
output "state_kms_key_arn" {
  description = "Llave KMS que cifra el estado."
  value       = aws_kms_key.terraform_state.arn
}

# Ruta del archivo backend.hcl que usa "terraform init" en el stack hub.
output "hub_backend_file" {
  description = "Archivo de configuración parcial del backend generado para el stack hub."
  value       = abspath(local_file.hub_backend_config.filename)
}

