# Cost guard. A monthly budget scoped to the demo's project tag, with email
# alerts. The standing compute (the instance, the load balancer, the address
# translation gateway) is what this catches; the per build cost is already
# bounded by the daily build cap in the control interface.

variable "budget_limit_usd" {
  type    = string
  default = "25"
}
variable "budget_email" {
  type    = string
  default = "anirban.kanjilal@gmail.com"
}

resource "aws_budgets_budget" "demo" {
  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$gha-ecs-runner-demo"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
