# Bài 5: sinh file cấu hình bằng templatefile (pattern dùng lại ở giai đoạn 3)
#
#   terraform apply && cat out/inventory.ini
#   Thử bỏ dấu ~ trong inventory.tftpl rồi apply lại: file sinh ra có thêm dòng trống
#   terraform console  →  thử: local.control_plane, keys(var.nodes), yamldecode(local_file.nodes_yaml.content)

terraform {
  required_version = ">= 1.9"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

locals {
  control_plane = { for k, v in var.nodes : k => v if v.role == "control_plane" }
  workers       = { for k, v in var.nodes : k => v if v.role == "worker" }
}

resource "local_file" "inventory" {
  filename        = "${path.module}/out/inventory.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    nodes        = var.nodes
    ansible_user = var.ansible_user
  })
}

# Cùng dữ liệu, định dạng YAML: không cần template, chỉ cần yamlencode
resource "local_file" "nodes_yaml" {
  filename        = "${path.module}/out/nodes.yml"
  file_permission = "0644"
  content = yamlencode({
    control_plane = { for k, v in local.control_plane : k => v.ip }
    workers       = { for k, v in local.workers : k => v.ip }
  })
}

output "inventory" {
  value = local_file.inventory.content
}
