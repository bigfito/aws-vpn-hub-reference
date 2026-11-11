
# =============================================================================
# locals.tf · Valores calculados que comparten varios archivos del hub
#
# Aquí se derivan, a partir de las variables, los valores que se repiten:
# el prefijo de nombres, los rangos de las subnets, la IP del DNS de la VPC y
# la lista de equipos de la LAN. También está la comprobación de que los rangos
# de IP no se traslapan (bloque check).
# =============================================================================

# Zonas de disponibilidad (AZ) activas de la región. Se usa la primera (y la
# segunda si enable_high_availability = true) para las subnets de la VPN.
data "aws_availability_zones" "available" {
  state = "available"
}

# Valores calculados. Se leen como local.<nombre> en los demás archivos.
locals {
  # Prefijo de todos los nombres de recursos: "vpn-hub-vpc", "vpn-hub-cvpn", …
  name_prefix = var.project_name

  # AZs donde se crea una subnet para el endpoint: 1, o 2 con alta disponibilidad.
  vpn_subnet_azs = slice(data.aws_availability_zones.available.names, 0, var.enable_high_availability ? 2 : 1)

  # Una subnet /24 por AZ dentro de la VPC: 10.80.1.0/24 (y 10.80.2.0/24).
  # cidrsubnet(10.80.0.0/16, 8, n) toma el bloque /24 número n de la VPC;
  # se empieza en 1 para dejar libre 10.80.0.0/24.
  vpn_subnet_cidrs_by_az = {
    for index, az in local.vpn_subnet_azs : az => cidrsubnet(var.vpc_cidr, 8, index + 1)
  }

  # Resolver DNS de la VPC: AWS lo pone siempre en la base de la VPC + 2
  # (10.80.0.2). Los clientes VPN lo usan para resolver vpn.example.internal.
  vpc_dns_server = cidrhost(var.vpc_cidr, 2)

  # Equipos de la LAN: los dispositivos con dns_updater = true. Son los que
  # registran su IP de túnel en la zona privada (la tableta no).
  home_devices = { for name, device in var.client_devices : name => device if device.dns_updater }

  # Carpeta donde se escriben los paquetes por dispositivo (terraform/hub/out).
  output_dir = "${path.module}/${var.client_output_dir}"

  # Rutas donde cada sistema operativo guarda el certificado y el helper de
  # IAM Roles Anywhere. Deben coincidir con los instaladores de ../../scripts.
  device_paths = {
    linux = {
      helper = "/usr/local/bin/aws_signing_helper"
      dir    = "/etc/vpn-hub"
    }
    windows = {
      helper = "C:\\Program Files\\vpn-hub\\aws_signing_helper.exe"
      dir    = "C:\\ProgramData\\vpn-hub"
    }
  }
}

# Comprobación: la VPC, el rango de clientes VPN y la LAN local no pueden
# compartir direcciones; si se traslapan, el tráfico no sabría a dónde ir.
# Un bloque "check" no detiene el apply, pero muestra la advertencia en cada plan.
check "cidrs_do_not_overlap" {
  assert {
    condition = alltrue([
      for pair in [
        [var.vpc_cidr, var.vpn_client_cidr],
        [var.vpc_cidr, var.home_lan_cidr],
        [var.vpn_client_cidr, var.home_lan_cidr],
      ] :
      # Dos rangos se traslapan si la base del más chico cae dentro del más grande:
      # se recorta la base del chico al prefijo del grande y se compara con la base del grande.
      !(
        tonumber(split("/", pair[0])[1]) <= tonumber(split("/", pair[1])[1])
        ? cidrhost(pair[0], 0) == cidrhost("${cidrhost(pair[1], 0)}/${split("/", pair[0])[1]}", 0)
        : cidrhost(pair[1], 0) == cidrhost("${cidrhost(pair[0], 0)}/${split("/", pair[1])[1]}", 0)
      )
    ])
    error_message = "vpc_cidr, vpn_client_cidr y home_lan_cidr no deben traslaparse."
  }
}

