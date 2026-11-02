# Bài 6: đóng gói thành module, gọi module bằng for_each
#
#   terraform init      (bắt buộc chạy lại mỗi khi thêm hoặc đổi module)
#   terraform apply
#   terraform state list   → địa chỉ dạng module.node["kubew1"].local_file.spec

terraform {
  required_version = ">= 1.9"
}

variable "nodes" {
  type = map(object({
    role = string
    ip   = string
  }))

  default = {
    "kubec1" = { role = "control_plane", ip = "10.10.10.51" }
    "kubew1" = { role = "worker", ip = "10.10.10.61" }
    "kubew2" = { role = "worker", ip = "10.10.10.62" }
  }
}

module "node" {
  source   = "./modules/node"
  for_each = var.nodes

  name    = each.key
  role    = each.value.role
  ip      = each.value.ip
  out_dir = "${path.module}/out"
}

# Gom output của từng instance module thành map name => ip
output "node_ips" {
  value = { for k, m in module.node : k => m.ip }
}
