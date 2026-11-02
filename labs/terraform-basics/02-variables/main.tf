# Bài 2: variable, validation, output, tfvars
#
# Thử truyền var.env theo 3 cách rồi xem cách nào thắng:
#   terraform plan -var env=prod
#   cp terraform.tfvars.example terraform.tfvars && terraform plan
#   TF_VAR_env=prod terraform plan
# Thử giá trị sai: terraform plan -var env=dev  → validation báo lỗi

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
  config = {
    env   = var.env
    owner = var.owner
  }
}

resource "local_file" "config" {
  filename = "${path.module}/out/config-${var.env}.json"
  content  = jsonencode(local.config)
}

# sensitive: plan hiển thị (sensitive value), nhưng hãy grep thử trong terraform.tfstate
resource "local_sensitive_file" "secret" {
  filename = "${path.module}/out/secret.txt"
  content  = var.api_token
}
