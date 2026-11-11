
# =============================================================================
# dns.tf · Zona DNS privada vpn.example.internal
#
# Client VPN da a cada dispositivo una IP de túnel distinta en cada conexión
# (10.81.x.x). Para que la tableta encuentre siempre a los equipos de la LAN por
# nombre (workstation-1.vpn.example.internal), cada equipo registra su IP actual en
# esta zona privada. Solo se resuelve dentro de la VPC, es decir, por la VPN.
#
# Los registros A los escriben los scripts de ../../scripts (actualizador de
# DNS), no Terraform, porque la IP cambia en cada conexión.
# Archivos relacionados: roles_anywhere.tf (permiso para escribir los registros).
# =============================================================================

# La zona privada, asociada a la VPC del hub para que su Resolver (10.80.0.2)
# la conozca.
resource "aws_route53_zone" "private_dns" {
  name    = var.private_zone_name
  comment = "${local.name_prefix}: IPs de tunel de los equipos de la LAN"
  # force_destroy: permite que "terraform destroy" borre la zona aunque tenga
  # los registros A que crearon los equipos (Terraform no los conoce).
  force_destroy = true

  vpc {
    vpc_id = aws_vpc.hub.id
  }
}

