variable "bucket_name" {
  description = "OSS bucket name"
  type        = string
}
variable "storage_class" {
  description = "OSS storage class (platform-resolved)"
  type        = string
}
variable "versioning" {
  description = "Enable versioning"
  type        = bool
  default     = false
}
variable "prefixes" {
  description = "Logical prefixes to pre-create"
  type        = list(string)
  default     = []
}
variable "encryption" {
  description = "Server-side encryption algorithm (platform-enforced)"
  type        = string
  default     = "KMS"
}
variable "tags" {
  description = "Service Governance tags (platform-injected)"
  type        = map(string)
  default     = {}
}
