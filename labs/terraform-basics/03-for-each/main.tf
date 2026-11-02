# Bài 3: count và for_each
#
# Cùng một danh sách node, được tạo theo 2 cách:
#   - local_file.by_key   : for_each theo map, địa chỉ kiểu by_key["kubew1"]
#   - local_file.by_index : count theo list,   địa chỉ kiểu by_index[1]
#
# Thí nghiệm: apply, rồi xoá "kubew1" (phần tử ở GIỮA) khỏi default trong variables.tf, rồi plan.
#   - by_key   : chỉ by_key["kubew1"] bị xoá, các node khác không bị đụng tới
#   - by_index : by_index[1] bị TẠO LẠI để mang dữ liệu của kubew2, by_index[2] bị xoá
#                → nếu đây là VM thì kubew2 đang chạy sẽ bị xoá rồi dựng lại!

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
  # map → list có thứ tự theo tên, để dùng cho count
  node_names = sort(keys(var.nodes))
}

resource "local_file" "by_key" {
  for_each = var.nodes

  filename = "${path.module}/out/by-key/${each.key}.txt"
  content  = <<-EOT
    name   = ${each.key}
    role   = ${each.value.role}
    ip     = ${each.value.ip}
    cores  = ${each.value.cores}
    memory = ${each.value.memory}
  EOT
}

resource "local_file" "by_index" {
  count = length(local.node_names)

  filename = "${path.module}/out/by-index/node-${count.index}.txt"
  content  = "${local.node_names[count.index]} ${var.nodes[local.node_names[count.index]].ip}\n"
}

output "files_by_key" {
  value = { for k, f in local_file.by_key : k => f.filename }
}

output "files_by_index" {
  value = local_file.by_index[*].filename
}
