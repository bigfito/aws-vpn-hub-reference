
# =============================================================================
# budget.tf · Presupuesto mensual con alertas por correo (opcional)
#
# Opcional. Con budget_alert_emails = [] el
# "count" vale 0 y no se crea nada. Para activarlo, pon uno o más correos en
# budget_alert_emails (terraform.tfvars) y vuelve a aplicar.
#
# El presupuesto filtra el costo por la etiqueta Project. Para que ese filtro
# vea gasto, la etiqueta debe estar activada como "etiqueta de asignación de
# costos" (Billing → Cost allocation tags; tarda hasta 24 h). En AWS
# Organizations, eso solo se puede hacer desde la cuenta de administración.
# =============================================================================

# El presupuesto (vpn-hub-monthly). "count" es el truco de Terraform para un
# recurso opcional: 1 = se crea, 0 = no existe.
resource "aws_budgets_budget" "monthly" {
  count = length(var.budget_alert_emails) > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Solo cuenta el gasto con la etiqueta Project = vpn-hub. format() arma el
  # texto "user:Project$vpn-hub" (el "$" separa la etiqueta de su valor).
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_name)]
  }

  # Alerta 1: el gasto REAL del mes pasó el 80 % del presupuesto.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Alerta 2: AWS PRONOSTICA que el mes cerrará por encima del 100 %.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

