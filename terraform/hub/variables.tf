
# =============================================================================
# variables.tf · Valores que puedes ajustar en el stack hub
#
# Los valores por defecto corresponden al diseño de docs/architecture.md.
# En terraform.tfvars (copia de terraform.tfvars.example, nunca versionado)
# solo hace falta poner owner y expected_account_id. Cambiar los rangos de IP
# o la zona DNS después del primer apply recrea recursos: revísalo antes.
# =============================================================================

# --- Cuenta, región y etiquetas ----------------------------------------------

# Región del hub. mx-central-1 (Querétaro) es una región "opt-in" que se
# habilitó para la cuenta en T0.3.
variable "aws_region" {
  description = "Región del hub de VPN."
  type        = string
  default     = "mx-central-1"
}

# Normalmente null: el perfil sale de AWS_PROFILE=vpn-hub y no se escribe aquí.
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

# Prefijo de nombres (local.name_prefix) y etiqueta Project.
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

# Etiqueta Owner. Sin valor por defecto a propósito: cada quien pone su nombre.
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

# --- Direccionamiento --------------------------------------------------------

# Rango privado de la VPC del hub. Se eligió 10.80.0.0/16 porque no choca con
# la LAN local (192.168.1.0/24) ni con el rango de clientes VPN.
variable "vpc_cidr" {
  description = "CIDR de la VPC del hub. No debe traslaparse con la LAN local ni con vpn_client_cidr."
  type        = string
  default     = "10.80.0.0/16"
}

# IPs que reciben los dispositivos al conectarse a la VPN (IP de túnel).
# AWS exige un tamaño entre /12 y /22, y el rango NO se puede cambiar después
# de crear el endpoint (habría que destruirlo y crearlo de nuevo).
# Un /22 son 1 024 direcciones: sobra para 5 equipos.
variable "vpn_client_cidr" {
  description = "Rango de IPs de túnel de los clientes VPN. Entre /12 y /22; no se puede cambiar después de crear el endpoint."
  type        = string
  default     = "10.81.0.0/22"

  validation {
    condition = (
      can(cidrhost(var.vpn_client_cidr, 0)) &&
      tonumber(split("/", var.vpn_client_cidr)[1]) >= 12 &&
      tonumber(split("/", var.vpn_client_cidr)[1]) <= 22
    )
    error_message = "vpn_client_cidr debe ser un CIDR IPv4 entre /12 y /22."
  }
}

# La LAN local no se configura en AWS: solo se usa en el bloque check de
# locals.tf para avisar si algún rango del hub se le traslapa.
variable "home_lan_cidr" {
  description = "LAN local. Solo se usa para validar que no haya traslape."
  type        = string
  default     = "192.168.1.0/24" # RFC 1918 documentation range; example hosts 192.168.1.10 and 192.168.1.20
}

# Una sola AZ por defecto: cada subnet asociada se cobra por hora. Con true se
# crea una segunda subnet en otra AZ para asociarla también si la primera falla.
variable "enable_high_availability" {
  description = "true crea una segunda subnet en otra AZ para asociarla también, desde la consola o con vpn-hub.sh (duplica el cobro por hora de asociación mientras está encendida)."
  type        = bool
  default     = false
}

# --- Client VPN --------------------------------------------------------------

# Duración máxima de una sesión VPN. AWS solo acepta 8, 10, 12 o 24 horas; al
# vencer, el cliente se reconecta solo (disconnect_on_session_timeout = false).
variable "session_timeout_hours" {
  description = "Duración máxima de la sesión VPN. Valores válidos: 8, 10, 12 o 24."
  type        = number
  default     = 24

  validation {
    condition     = contains([8, 10, 12, 24], var.session_timeout_hours)
    error_message = "session_timeout_hours debe ser 8, 10, 12 o 24."
  }
}

# Cuántos días guarda CloudWatch la bitácora de conexiones (quién se conectó,
# cuándo y desde qué IP).
variable "log_retention_days" {
  description = "Retención de la bitácora de conexiones en CloudWatch Logs."
  type        = number
  default     = 90
}

# Lista de dispositivos. Cada uno recibe su propio certificado y su paquete en
# out/<nombre>/. El nombre es a la vez el CN del certificado y el nombre DNS.
variable "client_devices" {
  description = <<-EOT
    Dispositivos que reciben certificado de cliente. La llave es el nombre del
    dispositivo: se usa como CN del certificado y como nombre DNS en la zona privada
    (<nombre>.<private_zone_name>), así que debe ir en minúsculas.
    os: linux | windows | ios. dns_updater: true si el equipo registra su IP de túnel
    (solo equipos linux o windows: la tableta no corre el actualizador).
  EOT
  type = map(object({
    os          = string
    dns_updater = bool
  }))
  default = {
    "tablet-1"      = { os = "ios", dns_updater = false }
    "workstation-1" = { os = "linux", dns_updater = true }
    "workstation-2" = { os = "windows", dns_updater = true }
  }

  # El nombre debe servir como etiqueta DNS (minúsculas, números y guiones).
  validation {
    condition     = alltrue([for name, device in var.client_devices : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", name)) && contains(["linux", "windows", "ios"], device.os)])
    error_message = "Los nombres deben ser etiquetas DNS en minúsculas y os debe ser linux, windows o ios."
  }

  # El actualizador de DNS solo existe para Linux y Windows (scripts y rutas en
  # locals.device_paths): un dispositivo ios no puede tener dns_updater = true.
  validation {
    condition     = alltrue([for name, device in var.client_devices : !(device.dns_updater && device.os == "ios")])
    error_message = "dns_updater = true solo es válido con os = linux o windows."
  }
}

# Vigencia de los certificados del servidor y de los dispositivos, en horas
# (17 520 h = 2 años). Terraform los renueva 30 días antes de vencer.
variable "certificate_validity_hours" {
  description = "Vigencia de los certificados de servidor y clientes (por defecto 2 años)."
  type        = number
  default     = 17520
}

# Vigencia de la CA, en horas (87 600 h = 10 años). Debe ser mayor que la de
# los certificados que firma.
variable "ca_validity_hours" {
  description = "Vigencia de la CA (por defecto 10 años)."
  type        = number
  default     = 87600
}

# --- DNS ---------------------------------------------------------------------

# Zona DNS privada. Las dos validaciones evitan nombres inválidos y el dominio
# .local, que en iPadOS, macOS y Ubuntu se resuelve por Multicast DNS y nunca
# llega al DNS de la VPN (ver docs/design-decisions.md).
variable "private_zone_name" {
  description = <<-EOT
    Zona privada de Route 53 donde los equipos de la LAN registran su IP de túnel.
    No uses .local: está reservado para Multicast DNS (RFC 6762) y iPadOS, macOS y
    Ubuntu (nss-mdns) no envían esas consultas al DNS de la VPN. .internal está
    reservado por ICANN para uso privado.
  EOT
  type        = string
  default     = "vpn.example.internal"

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.private_zone_name))
    error_message = "private_zone_name debe ser un nombre DNS en minúsculas, sin punto final."
  }

  validation {
    condition     = !endswith(var.private_zone_name, ".local")
    error_message = "No uses .local (reservado para Multicast DNS, RFC 6762). Usa .internal u otro dominio propio."
  }
}

# --- Costos ------------------------------------------------------------------

# Monto del presupuesto mensual. Solo se usa si budget_alert_emails tiene
# correos (desactivado por decisión de T0.4).
variable "monthly_budget_usd" {
  description = "Presupuesto mensual del proyecto en USD (solo se usa si budget_alert_emails no está vacío)."
  type        = number
  default     = 30 # pago por uso: ~USD 15/mes con ~60 h encendida
}

# Correos que reciben las alertas. Lista vacía = no se crea el presupuesto.
variable "budget_alert_emails" {
  description = "Correos que reciben las alertas del presupuesto. Vacío = no se crea el presupuesto."
  type        = list(string)
  default     = []
}

# --- Archivos locales generados ----------------------------------------------

# Carpeta, relativa a terraform/hub, donde se escriben los paquetes por
# dispositivo. Contienen llaves privadas: está en .gitignore.
variable "client_output_dir" {
  description = "Carpeta local donde se escriben los perfiles .ovpn y archivos por dispositivo (no versionar)."
  type        = string
  default     = "out"
}

