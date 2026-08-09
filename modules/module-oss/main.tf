resource "alicloud_oss_bucket" "this" {
  bucket        = var.bucket_name
  storage_class = var.storage_class
  tags          = var.tags
  versioning { status = var.versioning ? "Enabled" : "Suspended" }
  server_side_encryption_rule { sse_algorithm = var.encryption }
}
resource "alicloud_oss_bucket_object" "prefix" {
  count   = length(var.prefixes)
  bucket  = alicloud_oss_bucket.this.id
  key     = "${var.prefixes[count.index]}"
  content = ""
}
