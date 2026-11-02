# Bài 4: random, đồ thị phụ thuộc, buộc tạo lại
#
#   terraform graph | dot -Tsvg > graph.svg     (hoặc dán output vào https://dreampuf.github.io/GraphvizOnline)
#   terraform apply -var k8s_version=1.37.0      → token được sinh lại (keepers đổi)
#   terraform apply -var bump=2                  → bootstrap bị tạo lại (triggers_replace đổi)

terraform {
  required_version = ">= 1.9"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

variable "k8s_version" {
  type    = string
  default = "1.36.6"
}

variable "bump" {
  description = "Đổi số này để buộc terraform_data.bootstrap bị tạo lại"
  type        = number
  default     = 1
}

# Tên cluster: sinh một lần rồi giữ nguyên trong state cho tới khi destroy
resource "random_pet" "cluster" {
  length    = 2
  separator = "-"
}

# Token giả lập kiểu kubeadm (6.16 ký tự). Sinh lại khi k8s_version đổi.
resource "random_string" "token_id" {
  length  = 6
  special = false
  upper   = false
  keepers = {
    k8s_version = var.k8s_version
  }
}

resource "random_password" "token_secret" {
  length  = 16
  special = false
  upper   = false
  keepers = {
    k8s_version = var.k8s_version
  }
}

# File này phụ thuộc NGẦM vào 3 resource random ở trên (qua tham chiếu),
# nên Terraform tự biết phải tạo chúng trước, không cần depends_on.
resource "local_file" "cluster_info" {
  filename = "${path.module}/out/cluster-info.txt"
  content  = <<-EOT
    cluster     = ${random_pet.cluster.id}
    k8s_version = ${var.k8s_version}
    token       = ${random_string.token_id.result}.${random_password.token_secret.result}
  EOT
  # random_password là sensitive nên toàn bộ content cũng thành sensitive: plan sẽ không hiện nội dung
}

# terraform_data: resource "rỗng" thay cho null_resource, dùng để chứa dữ liệu hoặc kích hoạt provisioner
resource "terraform_data" "bootstrap" {
  triggers_replace = [var.bump]
  input            = random_pet.cluster.id

  provisioner "local-exec" {
    command = "echo 'bootstrap cluster ${self.input} (lần ${var.bump})' >> ${path.module}/out/bootstrap.log"
  }

  # depends_on chỉ cần khi phụ thuộc mà Terraform KHÔNG nhìn thấy qua tham chiếu:
  # provisioner ghi vào thư mục out/, mà thư mục này do local_file tạo ra.
  depends_on = [local_file.cluster_info]
}

output "cluster_name" {
  value = random_pet.cluster.id
}
