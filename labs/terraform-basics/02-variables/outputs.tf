output "config_file" {
  value = local_file.config.filename
}

output "config" {
  value = local.config
}

# Bỏ dòng sensitive = true → terraform sẽ báo lỗi, vì output đang lộ biến sensitive
output "api_token" {
  value     = var.api_token
  sensitive = true
}
