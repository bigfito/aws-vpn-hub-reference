
# =============================================================================
# network.tf · Red del hub: VPC, subnet del endpoint y security groups
#
# La VPC es solo el "punto de encuentro" de la VPN: no tiene servidores. El
# endpoint de Client VPN se conecta a ella a través de una subnet (la
# asociación, que se enciende en la consola o con vpn-hub.sh) y usa su DNS (10.80.0.2).
#
# No hay internet gateway ni NAT: AWS administra la cara pública del endpoint y,
# con split-tunnel, el tráfico a internet de cada cliente sale por su propia
# conexión. Así no se paga NAT ni IPv4 pública.
#
# Archivos relacionados: client_vpn.tf (endpoint) y dns.tf (zona privada).
# =============================================================================

# La VPC del hub (Name vpn-hub-vpc).
resource "aws_vpc" "hub" {
  cidr_block = var.vpc_cidr
  # Necesarios para que funcionen el Resolver DNS de la VPC (10.80.0.2) y la
  # zona privada de Route 53 asociada a ella.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Toda VPC trae un security group "default". Este bloque lo toma y lo deja SIN
# reglas, para que ningún recurso lo use por accidente con permisos abiertos.
resource "aws_default_security_group" "locked_default" {
  vpc_id = aws_vpc.hub.id

  tags = {
    Name = "${local.name_prefix}-default-locked"
  }
}

# Subnet(s) donde se conecta el endpoint cuando lo asocias (consola o vpn-hub.sh).
# Una por AZ (ver local.vpn_subnet_cidrs_by_az): 10.80.1.0/24 en mx-central-1a.
resource "aws_subnet" "vpn" {
  for_each = local.vpn_subnet_cidrs_by_az

  vpc_id            = aws_vpc.hub.id
  availability_zone = each.key
  cidr_block        = each.value
  # Subnet privada: nada de lo que se cree aquí recibe IP pública.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-cvpn-${each.key}"
  }
}

# Security group exclusivo del endpoint (Name vpn-hub-cvpn). Se aplica a las
# interfaces de red (ENI) que crea la asociación y define qué pueden alcanzar
# los clientes dentro de la VPC. Las reglas van en recursos separados (abajo).
resource "aws_security_group" "vpn_endpoint" {
  name        = "${local.name_prefix}-cvpn"
  description = "Client VPN endpoint ENIs"
  vpc_id      = aws_vpc.hub.id

  tags = {
    Name = "${local.name_prefix}-cvpn"
  }
}

# Salida permitida 1: consultas DNS por UDP al Resolver de la VPC (/32 = solo
# esa IP). Sin esta regla, los clientes no resolverían vpn.example.internal.
resource "aws_vpc_security_group_egress_rule" "vpn_endpoint_dns_udp" {
  security_group_id = aws_security_group.vpn_endpoint.id
  description       = "DNS al Resolver de la VPC"
  cidr_ipv4         = "${local.vpc_dns_server}/32"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

# Salida permitida 2: DNS por TCP (respuestas grandes que no caben en UDP).
resource "aws_vpc_security_group_egress_rule" "vpn_endpoint_dns_tcp" {
  security_group_id = aws_security_group.vpn_endpoint.id
  description       = "DNS al Resolver de la VPC"
  cidr_ipv4         = "${local.vpc_dns_server}/32"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
}

# Salida permitida 3: todo el tráfico hacia el rango de clientes VPN, para que
# la tableta llegue a los equipos de la LAN (escenario cliente-a-cliente).
# ip_protocol = "-1" significa "todos los protocolos".
resource "aws_vpc_security_group_egress_rule" "vpn_endpoint_to_clients" {
  security_group_id = aws_security_group.vpn_endpoint.id
  description       = "Trafico entre clientes VPN"
  cidr_ipv4         = var.vpn_client_cidr
  ip_protocol       = "-1"
}

