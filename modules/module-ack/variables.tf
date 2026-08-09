variable "cluster_name" {
  description = "ACK cluster name"
  type        = string
}
variable "worker_instance_type" {
  description = "Worker ECS instance type (platform-resolved from sizing map)"
  type        = string
}
variable "worker_count" {
  description = "Worker node count (platform-resolved)"
  type        = number
}
variable "namespaces" {
  description = "Namespaces to create"
  type        = list(string)
  default     = []
}
variable "vpc_id" {
  description = "VPC id (platform-injected)"
  type        = string
}
variable "vswitch_ids" {
  description = "VSwitch ids (platform-injected)"
  type        = list(string)
}
variable "enable_rrsa" {
  description = "Enable RAM Roles for Service Accounts"
  type        = bool
  default     = true
}
variable "tags" {
  description = "Service Governance tags (platform-injected)"
  type        = map(string)
  default     = {}
}
