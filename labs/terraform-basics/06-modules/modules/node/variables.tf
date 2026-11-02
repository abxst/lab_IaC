variable "name" {
  description = "Hostname của node"
  type        = string
}

variable "role" {
  type = string

  validation {
    condition     = contains(["control_plane", "worker"], var.role)
    error_message = "role phải là \"control_plane\" hoặc \"worker\"."
  }
}

variable "ip" {
  type = string
}

variable "out_dir" {
  description = "Thư mục ghi file mô tả node"
  type        = string
}
