
# =============================================================================
# account_guard.tf · Candado de cuenta (stack bootstrap)
#
# Este archivo no crea recursos: solo comprueba, en cada plan, apply y destroy,
# que el bucket del estado remoto se crea en la cuenta correcta, es decir, la
# cuenta miembro del proyecto (vpn-hub-prod) dentro de la OU
# root -> prod -> prj-vpn-hub de AWS Organizations.
#
# Hay dos candados que se complementan:
#   1. allowed_account_ids (en versions.tf): el proveedor se detiene si las
#      credenciales son de una cuenta distinta de var.expected_account_id.
#   2. La postcondición de abajo: aunque alguien escriba por error el ID de la
#      cuenta de administración en expected_account_id, el plan falla igual.
#
# La identidad de quien ejecuta (data.aws_caller_identity.current) se declara
# en main.tf, porque también da nombre al bucket.
# =============================================================================

# Datos básicos de la organización. Con return_organization_only = true el
# proveedor solo llama a DescribeOrganization, que cualquier cuenta miembro
# puede usar; sin esa opción también pediría la lista de cuentas, que solo la
# cuenta de administración puede leer. Si la cuenta no pertenece a ninguna
# organización, esta lectura falla con AWSOrganizationsNotInUseException.
data "aws_organizations_organization" "current" {
  return_organization_only = true

  lifecycle {
    # Nunca desplegar en la cuenta de administración de la organización: AWS
    # recomienda no poner cargas de trabajo ahí y las SCP no la protegen.
    postcondition {
      condition     = self.master_account_id != data.aws_caller_identity.current.account_id
      error_message = "Estas credenciales son de la cuenta de administración de AWS Organizations. El proyecto se despliega en la cuenta miembro de la OU root -> prod -> prj-vpn-hub: revisa AWS_PROFILE (debe ser vpn-hub)."
    }
  }
}

