output "policy_name" { value = alicloud_ram_policy.this.policy_name }
output "role_arn" { value = try(alicloud_ram_role.this[0].arn, "") }
