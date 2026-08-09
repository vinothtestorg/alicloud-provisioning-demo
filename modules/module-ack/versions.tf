terraform {
  required_version = ">= 1.9.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.240.0"
    }
  }
}
