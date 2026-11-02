variable "env" {
  description = "Môi trường triển khai"
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "prod"], var.env)
    error_message = "env chỉ được là \"lab\" hoặc \"prod\"."
  }
}

# Không có default → bắt buộc phải truyền. Thiếu thì terraform sẽ hỏi trên terminal
# (hoặc báo lỗi nếu chạy với -input=false, như trong CI).
variable "owner" {
  description = "Người sở hữu, ghi vào file"
  type        = string
}

variable "api_token" {
  description = "Giả lập một bí mật để xem sensitive hoạt động thế nào"
  type        = string
  default     = "token-gia-lap-123"
  sensitive   = true
}
