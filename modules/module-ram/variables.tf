variable "role_name" {
  description = "RAM role name"
  type        = string
  default     = ""
}
variable "trust_type" {
  description = "oidc for RRSA workload identity, or account for human roles"
  type        = string
  default     = "oidc"
}
variable "oidc_provider_arn" {
  description = "RAM OIDC provider ARN (from the cluster, cross-stack input)"
  type        = string
  default     = ""
}
variable "oidc_issuer_url" {
  description = "Cluster RRSA issuer URL (cross-stack input)"
  type        = string
  default     = ""
}
variable "service_account" {
  description = "namespace:serviceaccount this role may be assumed by"
  type        = string
  default     = ""
}
variable "group_name" {
  description = "RAM group for human users"
  type        = string
  default     = ""
}
variable "policy_name" {
  description = "RAM policy name"
  type        = string
}
variable "policy_actions" {
  description = "Allowed actions"
  type        = list(string)
}
variable "policy_resources" {
  description = "Resource ARNs the policy applies to"
  type        = list(string)
}
variable "tags" {
  description = "Service Governance tags (platform-injected)"
  type        = map(string)
  default     = {}
}
