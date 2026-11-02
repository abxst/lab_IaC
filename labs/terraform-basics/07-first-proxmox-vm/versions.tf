terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.119.0"
    }
  }
}

# Cấu hình kết nối lấy từ biến môi trường (file .envrc, giai đoạn 0 bước C5):
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE,
#   PROXMOX_VE_SSH_USERNAME, PROXMOX_VE_SSH_PRIVATE_KEY
# → không có bí mật nào nằm trong code.
provider "proxmox" {}
