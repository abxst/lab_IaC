# Module "node": một node → một file mô tả.
# Giai đoạn 3 thay local_file bằng proxmox_virtual_environment_vm, còn giao diện (variables/outputs) giữ gần như nguyên.

terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

resource "local_file" "spec" {
  filename = "${var.out_dir}/${var.name}.json"
  content = jsonencode({
    name = var.name
    role = var.role
    ip   = var.ip
  })
}

# Thí nghiệm moved: đổi tên resource "spec" ở trên thành "descriptor", rồi plan → Terraform muốn xoá và tạo lại.
# Bỏ comment khối dưới, rồi plan lại → Terraform chỉ đổi địa chỉ trong state, không xoá file nào.
#
# moved {
#   from = local_file.spec
#   to   = local_file.descriptor
# }
