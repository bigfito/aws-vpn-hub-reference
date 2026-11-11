
# =============================================================================
# client_profiles.tf · Paquete listo por dispositivo en ./out/<dispositivo>/
#
# Terraform no solo crea recursos en AWS: también escribe en tu equipo una
# carpeta por dispositivo que se copia tal cual (USB o red local) y contiene
# todo lo necesario para instalar la VPN. Contiene llaves privadas: out/ está en
# .gitignore y nunca se manda por correo ni a nubes de terceros.
#
#   Todos              vpn-hub-<dispositivo>.ovpn   perfil de OpenVPN con CA, certificado y llave embebidos
#                      LEEME.md                     pasos de instalación con los datos de ese equipo
#   Linux / Windows    install.sh | Install-VpnHub.ps1, vpn-hub-service (on/off) y scripts del actualizador de DNS
#   Equipos de la LAN  <dispositivo>.crt|key        certificado y llave para IAM Roles Anywhere
#   (dns_updater)      aws-config                   perfil de la CLI con credential_process
#                      dns-updater.env | .json      configuración del actualizador de DNS
#
# Las plantillas están en templates/ y los scripts en ../../scripts.
# =============================================================================

# Valores que usan los bloques de este archivo.
locals {
  # El endpoint publica su DNS como "*.cvpn-endpoint-....amazonaws.com". El
  # perfil usa el nombre sin "*." y la directiva remote-random-hostname, que le
  # antepone un prefijo aleatorio, igual que el archivo que da la consola.
  vpn_remote_host = trimprefix(aws_ec2_client_vpn_endpoint.vpn_endpoint.dns_name, "*.")

  # Nombre del perfil de la AWS CLI que usa el actualizador de DNS (vpn-hub-dns).
  dns_profile_name = "${local.name_prefix}-dns"

  # Carpeta de los scripts del repositorio.
  scripts_dir = "${path.module}/../../scripts"

  # Nombre del perfil .ovpn de cada dispositivo: vpn-hub-<dispositivo>.ovpn.
  ovpn_file_names = { for name, _ in var.client_devices : name => "${local.name_prefix}-${name}.ovpn" }

  # Scripts que se copian al paquete de cada equipo según su sistema operativo.
  scripts_by_os = {
    linux   = ["install.sh", "vpn-hub-service.sh", "vpn-hub-dns-update.sh", "vpn-hub-dns.service", "vpn-hub-dns.timer"]
    windows = ["Install-VpnHub.ps1", "vpn-hub-service.ps1", "vpn-hub-service.cmd", "Update-VpnHubDns.ps1"]
    ios     = []
  }

  # Lista plana "<dispositivo>/<script>" → origen, para crear un archivo por
  # cada combinación. merge([...]...) junta los mapas de todos los dispositivos.
  scripts_to_copy = merge([
    for name, device in var.client_devices : {
      for script in local.scripts_by_os[device.os] : "${name}/${script}" => {
        source     = "${local.scripts_dir}/${device.os}/${script}"
        executable = endswith(script, ".sh")
      }
    }
  ]...)

  # Nombres DNS completos de los equipos de la LAN (los muestra el LEEME de la tableta).
  home_device_fqdns = [for name, _ in local.home_devices : "${name}.${var.private_zone_name}"]
}

# Perfil .ovpn de cada dispositivo. "local_sensitive_file" evita que Terraform
# muestre su contenido (lleva la llave privada) en la pantalla del plan.
# Permisos 0600: solo el dueño del archivo puede leerlo.
resource "local_sensitive_file" "vpn_profile" {
  for_each = var.client_devices

  filename        = "${local.output_dir}/${each.key}/${local.ovpn_file_names[each.key]}"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/client.ovpn.tftpl", {
    device      = each.key
    project     = local.name_prefix
    remote_host = local.vpn_remote_host
    vpn_port    = aws_ec2_client_vpn_endpoint.vpn_endpoint.vpn_port
    dns_domain  = var.private_zone_name
    ca_cert     = tls_self_signed_cert.ca.cert_pem
    client_cert = tls_locally_signed_cert.device[each.key].cert_pem
    client_key  = tls_private_key.device[each.key].private_key_pem
  })
}

# LEEME.md de cada dispositivo, con los pasos de instalación y sus datos
# (nombre DNS, rangos para el firewall). Hay una plantilla por sistema operativo.
resource "local_file" "device_readme" {
  for_each = var.client_devices

  filename        = "${local.output_dir}/${each.key}/LEEME.md"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/leeme-${each.value.os}.md.tftpl", {
    device       = each.key
    ovpn_file    = local.ovpn_file_names[each.key]
    zone         = var.private_zone_name
    fqdn         = "${each.key}.${var.private_zone_name}"
    dns_updater  = each.value.dns_updater
    home_devices = local.home_device_fqdns
    client_cidr  = var.vpn_client_cidr
    vpc_cidr     = var.vpc_cidr
  })
}

# Copia los instaladores y scripts al paquete. Los .sh quedan ejecutables (0755).
# Se usa content = file(...) y no "source": con "source", Terraform no detecta
# que un script cambió y el paquete de out/ se quedaría con la versión vieja.
resource "local_file" "device_script" {
  for_each = local.scripts_to_copy

  filename        = "${local.output_dir}/${each.key}"
  content         = file(each.value.source)
  file_permission = each.value.executable ? "0755" : "0644"
}

# Certificado del equipo de la LAN en archivo aparte: aws_signing_helper lo
# presenta a IAM Roles Anywhere. Es público (no es secreto), por eso 0644.
resource "local_file" "device_cert" {
  for_each = local.home_devices

  filename        = "${local.output_dir}/${each.key}/${each.key}.crt"
  file_permission = "0644"
  content         = tls_locally_signed_cert.device[each.key].cert_pem
}

# Llave privada del equipo de la LAN en archivo aparte (para aws_signing_helper).
# Secreta: 0600 y local_sensitive_file.
resource "local_sensitive_file" "device_key" {
  for_each = local.home_devices

  filename        = "${local.output_dir}/${each.key}/${each.key}.key"
  file_permission = "0600"
  content         = tls_private_key.device[each.key].private_key_pem
}

# aws-config: perfil de la AWS CLI cuyo credential_process llama a
# aws_signing_helper para obtener credenciales temporales de Roles Anywhere.
# Las rutas cambian según el sistema operativo (local.device_paths).
resource "local_file" "device_aws_config" {
  for_each = local.home_devices

  filename        = "${local.output_dir}/${each.key}/aws-config"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/aws-config.tftpl", {
    device           = each.key
    profile_name     = local.dns_profile_name
    region           = var.aws_region
    helper           = local.device_paths[each.value.os].helper
    cert_path        = each.value.os == "windows" ? "${local.device_paths.windows.dir}\\${each.key}.crt" : "${local.device_paths.linux.dir}/${each.key}.crt"
    key_path         = each.value.os == "windows" ? "${local.device_paths.windows.dir}\\${each.key}.key" : "${local.device_paths.linux.dir}/${each.key}.key"
    trust_anchor_arn = aws_rolesanywhere_trust_anchor.vpn_ca.arn
    profile_arn      = aws_rolesanywhere_profile.dns_updater.arn
    role_arn         = aws_iam_role.dns_updater.arn
  })
}

# Linux: archivo de entorno que lee el servicio systemd vpn-hub-dns
# (scripts/linux/vpn-hub-dns.service). CLIENT_CIDR es el nombre que usa el script.
resource "local_file" "dns_updater_env" {
  for_each = { for name, device in local.home_devices : name => device if device.os == "linux" }

  filename        = "${local.output_dir}/${each.key}/dns-updater.env"
  file_permission = "0644"
  content         = <<-EOT
    RECORD_NAME=${each.key}.${var.private_zone_name}
    HOSTED_ZONE_ID=${aws_route53_zone.private_dns.zone_id}
    CLIENT_CIDR=${var.vpn_client_cidr}
    AWS_CONFIG_FILE=${local.device_paths.linux.dir}/aws-config
    AWS_PROFILE=${local.dns_profile_name}
  EOT
}

# Windows: configuración JSON que lee Update-VpnHubDns.ps1 (los nombres de
# campo son los que usa el script).
resource "local_file" "dns_updater_json" {
  for_each = { for name, device in local.home_devices : name => device if device.os == "windows" }

  filename        = "${local.output_dir}/${each.key}/dns-updater.json"
  file_permission = "0644"
  content = jsonencode({
    RecordName    = "${each.key}.${var.private_zone_name}"
    HostedZoneId  = aws_route53_zone.private_dns.zone_id
    ClientCidr    = var.vpn_client_cidr
    AwsConfigFile = "${local.device_paths.windows.dir}\\aws-config"
    AwsProfile    = local.dns_profile_name
  })
}

