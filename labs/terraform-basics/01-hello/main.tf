# Bài 1: resource đầu tiên và state
#
# Thí nghiệm (xem docs/01-terraform-basics.md):
#   1. apply → mở terraform.tfstate ra đọc
#   2. sửa out/hello.txt bằng tay → plan (drift)
#   3. xoá out/hello.txt → plan
#   4. đổi content bên dưới → plan, để ý "-/+" và "forces replacement"

terraform {
  required_version = ">= 1.9"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

resource "local_file" "hello" {
  filename        = "${path.module}/out/hello.txt"
  content         = "Xin chào từ Terraform!\n"
  file_permission = "0644"
}

output "file_path" {
  value = local_file.hello.filename
}
