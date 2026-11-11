
# =============================================================================
# versions.tf · Versiones, estado remoto y conexión a AWS (stack hub)
#
# El stack "hub" construye el hub de VPN: VPC, endpoint de AWS Client VPN,
# certificados, DNS privado e IAM Roles Anywhere. Este archivo fija las
# versiones de las herramientas, dónde se guarda el estado (S3, creado por el
# stack bootstrap) y cómo se conecta Terraform a AWS.
#
# Archivos relacionados: account_guard.tf (candado de cuenta) y
# ../bootstrap (crea el bucket y escribe backend.hcl).
# =============================================================================

# Versiones mínimas y backend. Terraform 1.10+ bloquea el estado con un archivo
# en S3 (use_lockfile), sin necesidad de una tabla de DynamoDB.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # Proveedor oficial de AWS; "~> 6.33" acepta 6.x desde 6.33, nunca 7.x.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.33"
    }
    # Proveedor "tls": genera la CA, las llaves y los certificados sin
    # herramientas externas (ver certificates.tf).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Proveedor "local": escribe en tu equipo los paquetes por dispositivo
    # (perfiles .ovpn, LEEME e instaladores; ver client_profiles.tf).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Configuración parcial: el archivo backend.hcl lo genera el stack bootstrap,
  # así este código no contiene el nombre del bucket ni el ARN de la llave.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

# Conexión a AWS. Región explícita y credenciales del perfil SSO "vpn-hub"
# (variable AWS_PROFILE); aws_profile queda en null salvo que lo pongas en
# terraform.tfvars.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Candado de cuenta: si las credenciales son de otra cuenta, el proveedor se
  # detiene antes de leer o cambiar nada (ver account_guard.tf).
  allowed_account_ids = [var.expected_account_id]

  # Etiquetas que AWS pone a TODOS los recursos del hub: permiten saber de qué
  # proyecto es cada uno. El costo se mide por la cuenta dedicada; filtrar por
  # Project en Cost Explorer exige activar la etiqueta (opcional, ver README).
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

