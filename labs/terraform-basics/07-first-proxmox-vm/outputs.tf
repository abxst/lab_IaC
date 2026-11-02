output "vm_id" {
  value = proxmox_virtual_environment_vm.sandbox.vm_id
}

output "ssh" {
  value = "ssh ansible@${var.ip}"
}

output "image_id" {
  description = "ID của cloud image trên Proxmox (dạng local:import/...)"
  value       = proxmox_download_file.noble.id
}
