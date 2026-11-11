
# =============================================================================
# versions.tf · Versiones de Terraform y del proveedor de AWS (stack bootstrap)
#
# El stack "bootstrap" crea, una sola vez, el lugar donde el stack "hub" guarda
# su estado: un bucket S3 cifrado con una llave KMS. Este archivo fija qué
# versiones de herramientas se usan y cómo se conecta Terraform a AWS.
#
# Archivos relacionados: account_guard.tf (candado de cuenta), main.tf (recursos)
# y variables.tf (valores que puedes ajustar).
# =============================================================================

# Versiones mínimas. Terraform 1.10 es la primera que permite bloquear el
# estado con un archivo en el mismo S3 (use_lockfile), sin tabla de DynamoDB.
# Este stack NO declara backend: su estado es local (terraform.tfstate en esta
# carpeta), porque el bucket remoto todavía no existe cuando se ejecuta.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # Proveedor oficial de AWS. "~> 6.33" acepta 6.33 o mayor, pero no 7.x,
    # para evitar cambios incompatibles de una versión mayor.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.33"
    }
    # Proveedor "local": escribe archivos en tu equipo (aquí, ../hub/backend.hcl).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Conexión a AWS. La región va siempre explícita (mx-central-1) y las
# credenciales salen del perfil SSO "vpn-hub" (variable AWS_PROFILE); aws_profile
# solo existe por si quieres indicarlo en terraform.tfvars, y por defecto es null.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Candado de cuenta: si las credenciales son de otra cuenta, el proveedor se
  # detiene antes de leer o cambiar nada (ver account_guard.tf).
  allowed_account_ids = [var.expected_account_id]

  # Etiquetas que AWS pone a TODOS los recursos de este stack. Sirven para
  # saber de qué proyecto es cada recurso, quién responde por él y, con la
  # etiqueta Project, para filtrar el costo en Cost Explorer si algún día se
  # activa como etiqueta de costos (opcional; hoy se mide por la cuenta dedicada).
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
    }
  }
}

