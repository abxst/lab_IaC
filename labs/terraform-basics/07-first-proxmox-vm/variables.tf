variable "pve_node" {
  description = "Tên node Proxmox"
  type        = string
  default     = "homelab"
}

variable "vm_id" {
  type    = number
  default = 199
}

variable "ip" {
  description = "IP tĩnh của VM sandbox (nằm ngoài dải DHCP của pfSense)"
  type        = string
  default     = "10.10.10.59"
}

variable "gateway" {
  type    = string
  default = "10.10.10.254"
}

variable "dns_servers" {
  type    = list(string)
  default = ["10.10.10.254"]
}

variable "dns_domain" {
  type    = string
  default = "hainth.local"
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/k8s_lab.pub"
}

variable "memory" {
  description = "RAM (MB). Thử đổi giá trị này rồi plan: VM được sửa tại chỗ, không bị tạo lại"
  type        = number
  default     = 2048
}
