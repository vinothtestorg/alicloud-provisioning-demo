output "bucket_name" { value = alicloud_oss_bucket.this.id }
output "bucket_arn" { value = "acs:oss:*:*:${alicloud_oss_bucket.this.id}" }
