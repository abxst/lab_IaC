output "name" {
  value = var.name
}

output "ip" {
  value = var.ip
}

output "spec_file" {
  value = local_file.spec.filename
}
