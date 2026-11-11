
# =============================================================================
# outputs.tf · Valores que el stack hub muestra al terminar
#
# Se consultan con "terraform output" o "terraform output -raw <nombre>".
# Los usan las personas (por ejemplo, para elegir la subnet al asociar el
# endpoint en la consola). Los scripts de tests/aws y scripts/aws/vpn-hub.sh no
# los leen: buscan los recursos por su etiqueta Name.
# Solo ca_private_key_pem es secreto: está marcado sensitive y no se muestra.
# =============================================================================

# ID del endpoint (cvpn-endpoint-…): lo piden los comandos de la AWS CLI.
output "client_vpn_endpoint_id" {
  description = "ID del endpoint de Client VPN."
  value       = aws_ec2_client_vpn_endpoint.vpn_endpoint.id
}

# Dirección pública del endpoint. No hace falta copiarla: ya va en los .ovpn.
output "client_vpn_dns_name" {
  description = "Nombre DNS del endpoint (los perfiles .ovpn ya lo incluyen)."
  value       = local.vpn_remote_host
}

# ID de la VPC del hub (vpn-hub-vpc).
output "vpc_id" {
  description = "ID de la VPC del hub."
  value       = aws_vpc.hub.id
}

# Subnet(s) que eliges en la consola al encender la VPN (Target network
# associations → Associate target network): ID y rango, por AZ.
output "vpn_subnets" {
  description = "Subnets para asociar el endpoint desde la consola, por AZ: id y cidr."
  value       = { for az, subnet in aws_subnet.vpn : az => { id = subnet.id, cidr = subnet.cidr_block } }
}

# IP del Resolver DNS de la VPC que reciben los clientes (10.80.0.2).
output "vpc_dns_server" {
  description = "Resolver de la VPC que usan los clientes."
  value       = local.vpc_dns_server
}

# ID de la zona privada; los equipos de la LAN lo tienen en su configuración.
output "private_zone_id" {
  description = "ID de la zona privada de Route 53."
  value       = aws_route53_zone.private_dns.zone_id
}

# Nombre DNS estable de cada equipo de la LAN (el que usas desde la tableta).
output "device_dns_names" {
  description = "Nombre DNS estable de cada equipo de la LAN."
  value       = { for name, _ in local.home_devices : name => "${name}.${var.private_zone_name}" }
}

# ARNs de IAM Roles Anywhere. Ya van dentro del aws-config de cada equipo; se
# muestran aquí para diagnóstico.
output "roles_anywhere" {
  description = "ARNs que usa aws_signing_helper en los equipos de la LAN."
  value = {
    trust_anchor_arn = aws_rolesanywhere_trust_anchor.vpn_ca.arn
    profile_arn      = aws_rolesanywhere_profile.dns_updater.arn
    role_arn         = aws_iam_role.dns_updater.arn
  }
}

# Carpeta completa de cada dispositivo (lo que se copia al equipo).
output "client_bundles" {
  description = "Carpeta lista por dispositivo (perfil .ovpn, LEEME e instaladores). Se copia tal cual al equipo."
  value       = { for name, _ in var.client_devices : name => abspath("${local.output_dir}/${name}") }
}

# Ruta del perfil .ovpn de cada dispositivo.
output "client_profiles" {
  description = "Perfil .ovpn de cada dispositivo."
  value       = { for name, file in local_sensitive_file.vpn_profile : name => abspath(file.filename) }
}

# Certificado público de la CA: se necesita para generar una lista de
# revocación (CRL) si se pierde un dispositivo. No es secreto.
output "ca_certificate_pem" {
  description = "Certificado público de la CA (para generar y verificar CRLs)."
  value       = tls_self_signed_cert.ca.cert_pem
}

# Llave privada de la CA. SECRETA: sensitive = true evita que se muestre; solo
# se lee a propósito con "terraform output -raw" para firmar una CRL.
output "ca_private_key_pem" {
  description = "Llave privada de la CA. Solo para generar una CRL; no la guardes en disco más tiempo del necesario."
  value       = tls_private_key.ca.private_key_pem
  sensitive   = true
}

