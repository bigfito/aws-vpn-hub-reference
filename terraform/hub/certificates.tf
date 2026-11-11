
# =============================================================================
# certificates.tf · Autoridad certificadora (CA) propia y certificados
#
# La VPN usa "autenticación mutua": el servidor y cada dispositivo se
# identifican con un certificado firmado por la misma CA. Si un certificado no
# lo firmó esta CA, AWS rechaza la conexión. La misma CA es además el "trust
# anchor" de IAM Roles Anywhere (roles_anywhere.tf).
#
# Reglas de AWS que este archivo respeta:
#   - Client VPN solo acepta llaves RSA de 1024 o 2048 bits.
#   - El certificado de cliente debe llevar el campo CN (common_name).
#   - El certificado del servidor se importa a ACM en la misma región.
# https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/mutual.html
#
# Las llaves privadas quedan en el estado de Terraform: por eso el estado vive
# en S3 cifrado con SSE-KMS (ver ../bootstrap) y nunca en git.
# =============================================================================

# --- Autoridad certificadora (CA) --------------------------------------------

# Llave privada de la CA. Quien la tenga puede firmar certificados válidos:
# es el secreto más importante del proyecto (solo vive en el estado cifrado).
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Certificado de la CA, firmado por ella misma ("self-signed"): es la raíz de
# confianza que reciben el endpoint, los perfiles .ovpn y Roles Anywhere.
resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = var.ca_validity_hours

  subject {
    common_name  = "${local.name_prefix}-ca"
    organization = local.name_prefix
  }

  # Una CA solo firma: certificados (cert_signing) y listas de revocación
  # (crl_signing, para revocar un dispositivo perdido).
  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# --- Servidor (el endpoint de Client VPN) ------------------------------------

# Llave privada del servidor VPN.
resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Solicitud de firma (CSR) del servidor. El nombre DNS no necesita existir:
# solo identifica al servidor dentro de nuestra propia CA.
resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  dns_names       = ["vpn-server.${var.private_zone_name}"]

  subject {
    common_name  = "vpn-server.${var.private_zone_name}"
    organization = local.name_prefix
  }
}

# Certificado del servidor, firmado por la CA.
resource "tls_locally_signed_cert" "server" {
  cert_request_pem      = tls_cert_request.server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = var.certificate_validity_hours
  # Terraform lo renueva automáticamente 30 días (720 h) antes de vencer.
  early_renewal_hours = 720

  # server_auth: este certificado solo sirve para identificar a un servidor.
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

# --- Dispositivos (un certificado por equipo) --------------------------------

# Llave privada de cada dispositivo (tablet, workstation-1, workstation-2). Viaja
# dentro de su perfil .ovpn: por eso el perfil es un secreto.
resource "tls_private_key" "device" {
  for_each = var.client_devices

  algorithm = "RSA"
  rsa_bits  = 2048
}

# Solicitud de firma de cada dispositivo. El CN es el nombre del dispositivo.
resource "tls_cert_request" "device" {
  for_each = var.client_devices

  private_key_pem = tls_private_key.device[each.key].private_key_pem

  subject {
    # El CN cumple tres funciones: AWS lo exige para la VPN, aparece como
    # nombre de la conexión en la bitácora y Roles Anywhere lo convierte en la
    # etiqueta x509Subject/CN que limita qué registro DNS puede actualizar.
    common_name  = each.key
    organization = local.name_prefix
  }
}

# Certificado de cada dispositivo, firmado por la CA.
resource "tls_locally_signed_cert" "device" {
  for_each = var.client_devices

  cert_request_pem      = tls_cert_request.device[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = var.certificate_validity_hours
  # Renovación automática 30 días antes de vencer (hay que reinstalar el perfil).
  early_renewal_hours = 720

  # client_auth: este certificado solo sirve para identificar a un cliente.
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

# --- ACM (AWS Certificate Manager) -------------------------------------------

# Importa el certificado del servidor a ACM, que es de donde lo toma el
# endpoint. Se incluye la CA como cadena: como los dispositivos usan la misma
# CA, el endpoint usa este mismo ARN para validar a los clientes.
resource "aws_acm_certificate" "vpn_server" {
  private_key       = tls_private_key.server.private_key_pem
  certificate_body  = tls_locally_signed_cert.server.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem

  tags = {
    Name = "${local.name_prefix}-server"
  }

  lifecycle {
    # Al renovar, se importa el certificado nuevo antes de borrar el viejo,
    # para que el endpoint nunca se quede sin certificado.
    create_before_destroy = true
  }
}

