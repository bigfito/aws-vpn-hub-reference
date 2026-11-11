
# =============================================================================
# roles_anywhere.tf · Permiso para que cada equipo de la LAN registre su nombre DNS
#
# El actualizador de DNS de workstation-1 y workstation-2 necesita credenciales de
# AWS para escribir en Route 53. En vez de guardar llaves de acceso en el
# equipo (que no vencen y se pueden filtrar), usa IAM Roles Anywhere: presenta
# el MISMO certificado de la VPN y recibe credenciales temporales (1 hora).
# https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html
#
# Mínimo privilegio: cada equipo solo puede hacer UPSERT del registro A con su
# propio nombre (<CN>.vpn.example.internal), gracias a la etiqueta de sesión
# x509Subject/CN que Roles Anywhere toma del certificado.
#
# Archivos relacionados: certificates.tf (CA y certificados), dns.tf (zona) y
# client_profiles.tf (aws-config que usa el equipo).
# =============================================================================

# "Trust anchor": le dice a Roles Anywhere que confíe en los certificados
# firmados por nuestra CA (la misma de la VPN).
resource "aws_rolesanywhere_trust_anchor" "vpn_ca" {
  name    = "${local.name_prefix}-ca"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = tls_self_signed_cert.ca.cert_pem
    }
  }
}

# Política de confianza del rol: QUIÉN puede asumirlo. Solo el servicio Roles
# Anywhere, solo a través de nuestro trust anchor y solo si el CN del
# certificado es el de un equipo de la LAN (la tableta queda fuera).
data "aws_iam_policy_document" "dns_updater_trust" {
  statement {
    effect = "Allow"
    # TagSession: Roles Anywhere agrega etiquetas a la sesión (entre ellas
    # x509Subject/CN). SetSourceIdentity: deja rastro del certificado en CloudTrail.
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
      "sts:SetSourceIdentity",
    ]

    principals {
      type        = "Service"
      identifiers = ["rolesanywhere.amazonaws.com"]
    }

    # Evita el "confused deputy": solo NUESTRO trust anchor puede usar el rol.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_rolesanywhere_trust_anchor.vpn_ca.arn]
    }

    # Solo los equipos de la LAN (workstation-1, workstation-2).
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/CN"
      values   = keys(local.home_devices)
    }
  }
}

# El rol que asumen los equipos de la LAN (vpn-hub-dns-updater). Las sesiones
# duran como máximo 1 hora; el actualizador pide credenciales nuevas cada vez.
resource "aws_iam_role" "dns_updater" {
  name                 = "${local.name_prefix}-dns-updater"
  description          = "Registra la IP de tunel de los equipos de la LAN en ${var.private_zone_name}"
  assume_role_policy   = data.aws_iam_policy_document.dns_updater_trust.json
  max_session_duration = 3600
}

# Permisos del rol: QUÉ puede hacer.
data "aws_iam_policy_document" "dns_updater" {
  # Solo crear o actualizar (UPSERT) registros A cuyo nombre sea el del propio
  # equipo. "ForAllValues" exige que TODOS los registros del cambio cumplan.
  statement {
    sid       = "UpsertOwnARecordOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.private_dns.arn]

    # "$${...}" escribe un "${...}" literal en la política: no lo resuelve
    # Terraform, lo resuelve IAM con el CN del certificado de quien llama.
    # Resultado: workstation-1 solo puede escribir workstation-1.vpn.example.internal.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["$${aws:PrincipalTag/x509Subject/CN}.${var.private_zone_name}"]
    }

    # Solo registros tipo A (dirección IPv4).
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A"]
    }

    # Solo UPSERT (crear o reemplazar); nunca DELETE.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"
      values   = ["UPSERT"]
    }
  }

  # No hay más permisos: los actualizadores comparan con su caché local (last-ip)
  # y no esperan a que el cambio se propague, así que no leen la zona.
}

# Adjunta la política de permisos al rol (política "inline": vive y se borra
# con el rol).
resource "aws_iam_role_policy" "dns_updater" {
  name   = "upsert-own-a-record"
  role   = aws_iam_role.dns_updater.id
  policy = data.aws_iam_policy_document.dns_updater.json
}

# Perfil de Roles Anywhere: une el trust anchor con el rol. El equipo lo indica
# en su aws-config (credential_process de aws_signing_helper).
resource "aws_rolesanywhere_profile" "dns_updater" {
  name      = "${local.name_prefix}-dns-updater"
  enabled   = true
  role_arns = [aws_iam_role.dns_updater.arn]
  # Duración de las credenciales temporales: 1 hora.
  duration_seconds = 3600
}

