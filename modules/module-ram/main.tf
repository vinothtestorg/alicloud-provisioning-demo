resource "alicloud_ram_policy" "this" {
  policy_name     = var.policy_name
  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect   = "Allow"
      Action   = var.policy_actions
      Resource = var.policy_resources
    }]
  })
}
resource "alicloud_ram_role" "this" {
  count       = var.role_name == "" ? 0 : 1
  name        = var.role_name
  document    = var.trust_type == "oidc" ? jsonencode({
    Version = "1"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Federated = [var.oidc_provider_arn] }
      Condition = {
        StringEquals = {
          "oidc:iss" = var.oidc_issuer_url
          "oidc:sub" = "system:serviceaccount:${var.service_account}"
        }
      }
    }]
  }) : jsonencode({
    Version = "1"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { RAM = ["acs:ram::*:root"] } }]
  })
}
resource "alicloud_ram_role_policy_attachment" "this" {
  count       = var.role_name == "" ? 0 : 1
  policy_name = alicloud_ram_policy.this.policy_name
  policy_type = "Custom"
  role_name   = alicloud_ram_role.this[0].name
}
resource "alicloud_ram_group" "this" {
  count = var.group_name == "" ? 0 : 1
  name  = var.group_name
}
resource "alicloud_ram_group_policy_attachment" "this" {
  count       = var.group_name == "" ? 0 : 1
  policy_name = alicloud_ram_policy.this.policy_name
  policy_type = "Custom"
  group_name  = alicloud_ram_group.this[0].name
}
