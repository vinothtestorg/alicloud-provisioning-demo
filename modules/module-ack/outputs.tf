output "cluster_id" { value = alicloud_cs_managed_kubernetes.this.id }
output "rrsa_oidc_issuer_url" { value = alicloud_cs_managed_kubernetes.this.rrsa_metadata[0].rrsa_oidc_issuer_url }
output "rrsa_provider_arn" { value = alicloud_cs_managed_kubernetes.this.rrsa_metadata[0].ram_oidc_provider_arn }
