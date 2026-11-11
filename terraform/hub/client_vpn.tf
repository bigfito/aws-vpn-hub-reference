
# =============================================================================
# client_vpn.tf · Endpoint de AWS Client VPN, bitácora y reglas de autorización
#
# El endpoint es el servidor VPN administrado por AWS. Los tres dispositivos se
# conectan a él como clientes; la tableta llega a los equipos de la LAN con el
# escenario oficial "cliente-a-cliente":
# https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/scenario-client-to-client.html
#
# Lo que NO está aquí, a propósito: la ASOCIACIÓN del endpoint con la subnet y
# la ruta 10.81.0.0/22 → local. AWS cobra por cada hora de asociación, así que
# la enciendes y apagas tú en la consola o con scripts/aws/vpn-hub.sh desde
# CloudShell (ver el comentario más abajo).
#
# Archivos relacionados: certificates.tf (ACM), network.tf (VPC, subnet, SG).
# =============================================================================

# Grupo de bitácoras en CloudWatch donde AWS anota cada conexión: dispositivo
# (CN), IP de origen, hora de inicio y de fin.
resource "aws_cloudwatch_log_group" "vpn_connections" {
  name              = "/aws/clientvpn/${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

# "Stream" (flujo) dentro del grupo donde el endpoint escribe los eventos.
resource "aws_cloudwatch_log_stream" "vpn_connections" {
  name           = "connections"
  log_group_name = aws_cloudwatch_log_group.vpn_connections.name
}

# El endpoint de Client VPN (Name vpn-hub-cvpn). Recién creado queda en estado
# "pending-associate": existe, pero nadie se puede conectar ni se cobra por hora
# hasta que lo asocias (consola o vpn-hub.sh).
resource "aws_ec2_client_vpn_endpoint" "vpn_endpoint" {
  description            = "${local.name_prefix} - acceso remoto cliente-a-cliente"
  server_certificate_arn = aws_acm_certificate.vpn_server.arn
  # IPs de túnel que reciben los dispositivos (10.81.0.0/22).
  client_cidr_block = var.vpn_client_cidr

  # UDP 443: el puerto de HTTPS rara vez está bloqueado en redes de terceros
  # (5G, Wi-Fi de otros proveedores) y UDP rinde mejor que TCP para una VPN.
  transport_protocol = "udp"
  vpn_port           = 443
  # Split-tunnel: solo viaja por la VPN el tráfico hacia la VPC y hacia los
  # otros clientes; el resto (internet) sale directo por la conexión de cada
  # dispositivo. Así no se paga NAT ni se hace lento el resto del tráfico.
  split_tunnel = true
  # DNS que reciben los clientes: el Resolver de la VPC, que conoce la zona
  # privada vpn.example.internal.
  dns_servers = [local.vpc_dns_server]

  vpc_id             = aws_vpc.hub.id
  security_group_ids = [aws_security_group.vpn_endpoint.id]

  # Los equipos de la LAN corren OpenVPN como servicio mientras estás fuera: si una
  # conexión llega a la sesión máxima, el cliente se reconecta solo en lugar de
  # quedar desconectado. Se declara explícito porque el default de la API es true.
  # ⚠️ El proveedor AWS 6.71.0 NO envía este false al CREAR el endpoint: AWS lo
  # deja en true y el siguiente plan propone "true -> false". Tras crear (o
  # recrear) el endpoint hace falta un segundo apply; verify-hub.sh lo detecta.
  session_timeout_hours         = var.session_timeout_hours
  disconnect_on_session_timeout = false

  # El portal de autoservicio solo existe con autenticación por usuario (SAML);
  # con certificados no aplica.
  self_service_portal = "disabled"

  authentication_options {
    type = "certificate-authentication"
    # Certificado contra el que se validan los clientes. Es el mismo ARN del
    # servidor porque servidor y dispositivos los firma la misma CA.
    root_certificate_chain_arn = aws_acm_certificate.vpn_server.arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.vpn_connections.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.vpn_connections.name
  }

  tags = {
    Name = "${local.name_prefix}-cvpn"
  }
}

# --- Asociación y ruta cliente-a-cliente: SE MANEJAN FUERA DE TERRAFORM -------
#
# AWS cobra por cada hora que el endpoint está asociado a una subnet. Para pagar
# solo mientras el túnel está encendido a propósito, la asociación NO la crea Terraform: la
# enciendes y apagas tú desde la consola de AWS o con scripts/aws/vpn-hub.sh en
# CloudShell (también desde la tableta). La ruta local desaparece al desasociar y
# se crea en cada asociación (el script lo hace solo). Pasos:
# docs/client-setup.md §0. La subnet a elegir es la del output
# vpn_subnets. Así un "terraform apply" nunca enciende ni apaga la VPN por
# sorpresa. Antes de "terraform destroy" hay que desasociar.

# Autorización 1: permite a todos los clientes llegar a la VPC. Es necesaria
# aunque la VPC no tenga servidores, porque ahí vive el DNS (10.80.0.2).
resource "aws_ec2_client_vpn_authorization_rule" "allow_vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.vpn_endpoint.id
  target_network_cidr    = var.vpc_cidr
  # "Todos los grupos": con certificados no hay grupos de usuarios que filtrar.
  authorize_all_groups = true
  description          = "VPC del hub y Resolver DNS"
}

# Autorización 2: permite el tráfico entre clientes (tablet <-> equipos de la LAN).
# Sin ella, la ruta local existiría pero AWS bloquearía el tráfico.
resource "aws_ec2_client_vpn_authorization_rule" "allow_client_to_client" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.vpn_endpoint.id
  target_network_cidr    = var.vpn_client_cidr
  authorize_all_groups   = true
  description            = "Cliente a cliente"
}

