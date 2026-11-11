
# =============================================================================
# variables.tf · Valores que puedes ajustar en el stack bootstrap
#
# Cada variable tiene un valor por defecto pensado para este proyecto, salvo
# owner y expected_account_id, que debes poner en terraform.tfvars (copia
# terraform.tfvars.example). terraform.tfvars nunca se versiona.
# =============================================================================

# --- Cuenta, región y etiquetas ----------------------------------------------

# Región del bucket. mx-central-1 (Querétaro) es una región "opt-in": se
# habilita para la cuenta desde la cuenta de administración (T0.3).
variable "aws_region" {
  description = "Región donde vive el bucket del estado remoto."
  type        = string
  default     = "mx-central-1"
}

# Normalmente se deja en null y el perfil sale de la variable de entorno
# AWS_PROFILE=vpn-hub, para no escribir nombres de perfil en el código.
variable "aws_profile" {
  description = "Perfil de la CLI de AWS a usar. null usa la cadena de credenciales por defecto (AWS_PROFILE)."
  type        = string
  default     = null
}

# Candado de cuenta (ver account_guard.tf). Va en terraform.tfvars, que no se
# versiona, porque el ID de la cuenta no debe quedar en el repositorio.
variable "expected_account_id" {
  description = "ID (12 dígitos) de la cuenta miembro del proyecto en la OU root/prod/prj-vpn-hub. Terraform se niega a trabajar en cualquier otra cuenta (ver account_guard.tf)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id debe tener exactamente 12 dígitos. Obtenlo con: aws sts get-caller-identity --profile vpn-hub --query Account --output text"
  }
}

# Prefijo de los nombres de recursos (bucket, alias de KMS) y etiqueta Project.
variable "project_name" {
  description = "Nombre corto del proyecto; prefija los nombres de recursos."
  type        = string
  default     = "vpn-hub"
}

# Etiqueta Environment de todos los recursos.
variable "environment" {
  description = "Etiqueta Environment."
  type        = string
  default     = "prod" # coincide con la OU prod donde vive la cuenta
}

# Etiqueta Owner: quién responde por los recursos. Sin valor por defecto a
# propósito, para que cada quien ponga su nombre.
variable "owner" {
  description = "Etiqueta Owner (responsable del recurso)."
  type        = string
}

# Etiqueta CostCenter, útil para agrupar costos.
variable "cost_center" {
  description = "Etiqueta CostCenter."
  type        = string
  default     = "example"
}

# --- Limpieza y retención ----------------------------------------------------

# true = "terraform destroy" puede borrar el bucket aunque tenga versiones.
# Se deja en true porque todo lo del proyecto debe poder destruirse.
variable "force_destroy_state_bucket" {
  description = "true permite que terraform destroy borre el bucket del estado con todas sus versiones. Destruye antes el stack hub."
  type        = bool
  default     = true
}

# KMS no borra llaves al instante: este es el plazo de gracia (7 a 30 días,
# límites de AWS). 7 es el mínimo, para que la limpieza termine pronto.
variable "kms_deletion_window_days" {
  description = "Días que KMS espera antes de borrar la llave tras un destroy (7 a 30)."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days debe estar entre 7 y 30."
  }
}

# Cuánto tiempo se guardan las versiones anteriores del estado (para poder
# volver atrás si algo sale mal).
variable "noncurrent_version_retention_days" {
  description = "Días que se conservan las versiones anteriores del estado."
  type        = number
  default     = 90
}

