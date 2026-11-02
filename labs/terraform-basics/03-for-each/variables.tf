variable "nodes" {
  description = "Danh sách node của cluster, key là hostname"
  type = map(object({
    role   = string
    ip     = string
    cores  = number
    memory = number
  }))

  default = {
    "kubec1" = { role = "control_plane", ip = "10.10.10.51", cores = 2, memory = 3072 }
    "kubew1" = { role = "worker", ip = "10.10.10.61", cores = 2, memory = 3072 }
    "kubew2" = { role = "worker", ip = "10.10.10.62", cores = 2, memory = 3072 }
  }

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["control_plane", "worker"], n.role)])
    error_message = "role phải là \"control_plane\" hoặc \"worker\"."
  }
}
