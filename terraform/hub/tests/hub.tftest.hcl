
# =============================================================================
# hub.tftest.hcl · Pruebas unitarias del stack hub (terraform test)
#
# Comprueban las reglas del diseño (docs/design-decisions.md) SIN tocar AWS: los proveedores aws, tls y local son simulados
# (mock_provider), así que no hacen falta credenciales ni se escriben archivos.
#
# Cómo se ejecuta (desde la raíz del repositorio):
#   terraform -chdir=terraform/hub test
# (Si el stack nunca se inicializó, antes: terraform -chdir=terraform/hub init
# -backend=false. Con el backend S3 ya configurado ese init pide credenciales.)
#
# Cada bloque "run" es un caso: arma un plan con las variables indicadas y
# revisa sus "assert". Si un caso usa "expect_failures", lo correcto es que esa
# validación FALLE (así se prueba que la protección existe).
#
# Los IDs de cuenta de aquí (111111111111 y 999999999999) son ficticios.
# =============================================================================

# Proveedor de AWS simulado. Los bloques mock_data y mock_resource fijan los
# valores que AWS calcularía; todo lo demás lo inventa Terraform.
mock_provider "aws" {
  # Cuenta "actual" ficticia: la misma que expected_account_id (abajo).
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }

  # La cuenta de administración de la organización es OTRA: el candado de
  # cuenta (account_guard.tf) debe dejar pasar el plan.
  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "999999999999" }
  }

  # Zonas de disponibilidad de mx-central-1 (las subnets se crean en ellas).
  mock_data "aws_availability_zones" {
    defaults = { names = ["mx-central-1a", "mx-central-1b", "mx-central-1c"] }
  }

  # Sin esto, el JSON simulado sería texto al azar y la política de IAM no
  # sería un documento válido.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }

  # Nombre DNS con la forma real del endpoint ("*." + nombre).
  mock_resource "aws_ec2_client_vpn_endpoint" {
    defaults = { dns_name = "*.cvpn-endpoint-0123456789abcdef0.prod.clientvpn.mx-central-1.amazonaws.com" }
  }
}

# Certificados y archivos locales simulados: no se generan llaves reales ni se
# escribe nada en terraform/hub/out/.
mock_provider "tls" {}
mock_provider "local" {}

# Variables obligatorias para todos los casos (las demás usan su default).
variables {
  owner               = "pruebas"
  expected_account_id = "111111111111"
}

# -----------------------------------------------------------------------------
# Red y DNS
# -----------------------------------------------------------------------------

# Direccionamiento por defecto: VPC, subnet del endpoint y DNS de los clientes.
run "direccionamiento_por_defecto" {
  command = plan

  assert {
    condition     = aws_vpc.hub.cidr_block == "10.80.0.0/16"
    error_message = "La VPC del hub debe ser 10.80.0.0/16."
  }

  assert {
    condition     = length(aws_subnet.vpn) == 1 && aws_subnet.vpn["mx-central-1a"].cidr_block == "10.80.1.0/24"
    error_message = "Sin alta disponibilidad debe haber una sola subnet: 10.80.1.0/24 en mx-central-1a."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.client_cidr_block == "10.81.0.0/22"
    error_message = "El client CIDR debe ser 10.81.0.0/22."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.dns_servers == tolist(["10.80.0.2"]) && output.vpc_dns_server == "10.80.0.2"
    error_message = "Los clientes deben usar el Resolver de la VPC, 10.80.0.2."
  }

  assert {
    condition     = aws_route53_zone.private_dns.name == "vpn.example.internal"
    error_message = "La zona privada debe ser vpn.example.internal."
  }
}

# Traslape: una VPC 192.168.0.0/16 choca con la LAN de ejemplo
# (192.168.1.0/24), así que el check cidrs_do_not_overlap debe fallar.
run "traslape_con_la_lan_de_ejemplo_falla" {
  command = plan

  variables {
    vpc_cidr = "192.168.0.0/16"
  }

  expect_failures = [check.cidrs_do_not_overlap]
}

# Zona .local: está reservada para Multicast DNS y la validación la rechaza.
run "zona_local_falla" {
  command = plan

  variables {
    private_zone_name = "vpn.example.local"
  }

  expect_failures = [var.private_zone_name]
}

# Alta disponibilidad: dos subnets (dos AZ) y dos entradas en el output.
run "alta_disponibilidad" {
  command = plan

  variables {
    enable_high_availability = true
  }

  assert {
    condition     = length(aws_subnet.vpn) == 2 && aws_subnet.vpn["mx-central-1b"].cidr_block == "10.80.2.0/24"
    error_message = "Con alta disponibilidad debe haber 2 subnets; la segunda, 10.80.2.0/24 en mx-central-1b."
  }

  assert {
    condition     = length(output.vpn_subnets) == 2
    error_message = "El output vpn_subnets debe tener 2 entradas con alta disponibilidad."
  }
}

# -----------------------------------------------------------------------------
# Endpoint de Client VPN
# -----------------------------------------------------------------------------

# Opciones del endpoint: split-tunnel, sesión de 24 h que se reconecta sola y
# UDP 443.
run "opciones_del_endpoint" {
  command = plan

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.split_tunnel == true
    error_message = "split_tunnel debe ser true (solo el tráfico privado va por la VPN)."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.session_timeout_hours == 24
    error_message = "session_timeout_hours debe ser 24."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.disconnect_on_session_timeout == false
    error_message = "disconnect_on_session_timeout debe ser false (el cliente se reconecta al vencer la sesión)."
  }

  assert {
    condition     = aws_ec2_client_vpn_endpoint.vpn_endpoint.vpn_port == 443 && aws_ec2_client_vpn_endpoint.vpn_endpoint.transport_protocol == "udp"
    error_message = "El endpoint debe escuchar en UDP 443."
  }
}

# Cliente-a-cliente: la asociación del endpoint y la ruta "local" se manejan en
# la consola o con vpn-hub.sh, así que ningún .tf del stack puede declararlas. terraform test no
# puede listar los tipos de recurso de un plan, por eso se revisa el código: el
# stack no usa módulos, de modo que "ningún .tf las declara" equivale a "el plan
# no las contiene".
run "sin_asociacion_ni_ruta_local" {
  command = plan

  assert {
    condition = alltrue([
      for file_name in fileset(path.module, "*.tf") :
      length(regexall("resource\\s+\"aws_ec2_client_vpn_(network_association|route)\"", file("${path.module}/${file_name}"))) == 0
    ])
    error_message = "Ningún .tf debe declarar aws_ec2_client_vpn_network_association ni aws_ec2_client_vpn_route: se manejan en la consola o con vpn-hub.sh."
  }

  assert {
    condition     = length(fileset(path.module, "*.tf")) >= 10
    error_message = "No se encontraron los .tf del stack (¿cambió path.module?)."
  }
}

# Autorizaciones: exactamente dos, la VPC (DNS) y el client CIDR (cliente-a-cliente).
run "dos_autorizaciones" {
  command = plan

  assert {
    condition     = aws_ec2_client_vpn_authorization_rule.allow_vpc.target_network_cidr == "10.80.0.0/16" && aws_ec2_client_vpn_authorization_rule.allow_vpc.authorize_all_groups == true
    error_message = "La primera autorización debe ser la VPC 10.80.0.0/16 para todos los grupos."
  }

  assert {
    condition     = aws_ec2_client_vpn_authorization_rule.allow_client_to_client.target_network_cidr == "10.81.0.0/22" && aws_ec2_client_vpn_authorization_rule.allow_client_to_client.authorize_all_groups == true
    error_message = "La segunda autorización debe ser el client CIDR 10.81.0.0/22 para todos los grupos."
  }

  assert {
    condition = alltrue([
      for file_name in fileset(path.module, "*.tf") :
      length(regexall("resource\\s+\"aws_ec2_client_vpn_authorization_rule\"", file("${path.module}/${file_name}"))) == (file_name == "client_vpn.tf" ? 2 : 0)
    ])
    error_message = "Debe haber exactamente dos reglas de autorización, ambas en client_vpn.tf."
  }
}

# -----------------------------------------------------------------------------
# IAM y destrucción
# -----------------------------------------------------------------------------

# Política del actualizador de DNS: cada equipo solo puede hacer UPSERT de un
# registro A con su propio nombre (el CN de su certificado).
run "politica_del_actualizador_de_dns" {
  command = plan

  # Mínimo privilegio: el único permiso es ese UPSERT; los actualizadores no leen la zona.
  assert {
    condition     = length(data.aws_iam_policy_document.dns_updater.statement) == 1
    error_message = "La política del actualizador de DNS debe tener un solo permiso: el UPSERT de su registro A."
  }

  assert {
    condition = anytrue([
      for condition in data.aws_iam_policy_document.dns_updater.statement[0].condition :
      condition.variable == "route53:ChangeResourceRecordSetsNormalizedRecordNames" &&
      contains(condition.values, "$${aws:PrincipalTag/x509Subject/CN}.vpn.example.internal")
    ])
    error_message = "La política debe limitar el nombre a $${aws:PrincipalTag/x509Subject/CN}.vpn.example.internal."
  }

  assert {
    condition = anytrue([
      for condition in data.aws_iam_policy_document.dns_updater.statement[0].condition :
      condition.variable == "route53:ChangeResourceRecordSetsActions" && toset(condition.values) == toset(["UPSERT"])
    ])
    error_message = "La única acción permitida debe ser UPSERT."
  }

  assert {
    condition = anytrue([
      for condition in data.aws_iam_policy_document.dns_updater.statement[0].condition :
      condition.variable == "route53:ChangeResourceRecordSetsRecordTypes" && toset(condition.values) == toset(["A"])
    ])
    error_message = "El único tipo de registro permitido debe ser A."
  }

  assert {
    condition = anytrue([
      for condition in data.aws_iam_policy_document.dns_updater_trust.statement[0].condition :
      condition.variable == "aws:PrincipalTag/x509Subject/CN" && toset(condition.values) == toset(["workstation-2", "workstation-1"])
    ])
    error_message = "Solo los equipos de la LAN (no la tableta) pueden asumir el rol del actualizador de DNS."
  }
}

# Destrucción: la zona privada se borra aunque tenga registros A.
run "zona_destruible" {
  command = plan

  assert {
    condition     = aws_route53_zone.private_dns.force_destroy == true
    error_message = "aws_route53_zone.private_dns debe tener force_destroy = true."
  }
}

# -----------------------------------------------------------------------------
# Presupuesto
# -----------------------------------------------------------------------------

# Sin correos no se crea el presupuesto.
run "sin_presupuesto_por_defecto" {
  command = plan

  assert {
    condition     = length(aws_budgets_budget.monthly) == 0
    error_message = "Sin budget_alert_emails no debe crearse el presupuesto."
  }
}

# Con al menos un correo se crea exactamente un presupuesto.
run "presupuesto_con_correos" {
  command = plan

  variables {
    budget_alert_emails = ["alertas@example.com"]
  }

  assert {
    condition     = length(aws_budgets_budget.monthly) == 1
    error_message = "Con budget_alert_emails debe crearse un presupuesto."
  }
}

# -----------------------------------------------------------------------------
# Paquetes por dispositivo (terraform/hub/out/)
# -----------------------------------------------------------------------------

# Un .ovpn por dispositivo; solo los equipos de la LAN llevan los archivos del
# actualizador de DNS, y cada uno recibe los scripts de su sistema operativo.
run "paquetes_por_dispositivo" {
  command = plan

  assert {
    condition     = keys(local_sensitive_file.vpn_profile) == ["tablet-1", "workstation-1", "workstation-2"]
    error_message = "Debe haber un perfil .ovpn por dispositivo (workstation-2, workstation-1, tablet-1)."
  }

  assert {
    condition     = endswith(local_sensitive_file.vpn_profile["tablet-1"].filename, "out/tablet-1/vpn-hub-tablet-1.ovpn")
    error_message = "El perfil de la tableta debe ser out/tablet-1/vpn-hub-tablet-1.ovpn."
  }

  assert {
    condition     = keys(local_file.device_aws_config) == ["workstation-1", "workstation-2"]
    error_message = "Solo los equipos de la LAN llevan aws-config; la tableta no."
  }

  assert {
    condition     = keys(local_sensitive_file.device_key) == ["workstation-1", "workstation-2"] && keys(local_file.device_cert) == ["workstation-1", "workstation-2"]
    error_message = "Solo los equipos de la LAN llevan certificado y llave para Roles Anywhere."
  }

  assert {
    condition     = keys(local_file.dns_updater_env) == ["workstation-1"] && keys(local_file.dns_updater_json) == ["workstation-2"]
    error_message = "workstation-1 (Linux) lleva dns-updater.env y workstation-2 (Windows) dns-updater.json."
  }

  assert {
    condition = (
      length(local_file.device_script) == 9 &&
      contains(keys(local_file.device_script), "workstation-1/vpn-hub-service.sh") &&
      contains(keys(local_file.device_script), "workstation-2/vpn-hub-service.cmd") &&
      length([for key in keys(local_file.device_script) : key if startswith(key, "tablet-1/")]) == 0
    )
    error_message = "Linux recibe 5 scripts, Windows 4 y la tableta ninguno."
  }

  assert {
    condition     = local_file.device_script["workstation-1/install.sh"].file_permission == "0755" && local_file.device_script["workstation-2/Install-VpnHub.ps1"].file_permission == "0644"
    error_message = "Los .sh deben quedar ejecutables (0755) y el resto en 0644."
  }

  assert {
    condition     = local_sensitive_file.vpn_profile["workstation-1"].file_permission == "0600" && local_sensitive_file.device_key["workstation-1"].file_permission == "0600"
    error_message = "Los archivos con llaves privadas deben tener permisos 0600."
  }
}

# -----------------------------------------------------------------------------
# Candado de cuenta (account_guard.tf)
# -----------------------------------------------------------------------------

# En la cuenta miembro (distinta de la de administración) el plan pasa.
run "cuenta_miembro_pasa" {
  command = plan

  assert {
    condition     = data.aws_organizations_organization.current.master_account_id != data.aws_caller_identity.current.account_id
    error_message = "Con la cuenta de administración distinta de la actual, el plan debe pasar."
  }
}

# Si las credenciales son de la cuenta de administración, la postcondición
# detiene el plan.
run "cuenta_de_administracion_falla" {
  command = plan

  override_data {
    target = data.aws_organizations_organization.current
    values = { master_account_id = "111111111111" }
  }

  expect_failures = [data.aws_organizations_organization.current]
}

# -----------------------------------------------------------------------------
# Validación de client_devices (variables.tf)
# -----------------------------------------------------------------------------

# Un tablet (ios) con dns_updater = true no pasa la validación: el actualizador
# de DNS solo existe para Linux y Windows.
run "ios_con_actualizador_de_dns_falla" {
  command = plan

  variables {
    client_devices = {
      "tablet-1" = { os = "ios", dns_updater = true }
    }
  }

  expect_failures = [var.client_devices]
}

# Un ID de cuenta que no tiene 12 dígitos no pasa la validación.
run "id_de_cuenta_invalido_falla" {
  command = plan

  variables {
    expected_account_id = "123"
  }

  expect_failures = [var.expected_account_id]
}

