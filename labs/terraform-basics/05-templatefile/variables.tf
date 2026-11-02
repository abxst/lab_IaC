variable "nodes" {
  description = "Danh sách node của cluster, key là hostname"
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

variable "ansible_user" {
  type    = string
  default = "ansible"
}
