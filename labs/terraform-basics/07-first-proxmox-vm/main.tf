# Bài 7: VM thật đầu tiên trên Proxmox, từ Ubuntu cloud image (chưa cần Packer/template)
#
#   terraform apply
#   ssh ansible@10.10.10.59
#   Mở Proxmox → VM 199 → tab Cloud-Init để xem Terraform đã điền gì.
#   Thí nghiệm: đổi var.memory → plan (sửa tại chỗ);  đổi var.vm_id → plan (tạo lại)
#   GIỮ VM này để làm giai đoạn 2, xong giai đoạn 2 thì destroy.

# Tải cloud image về storage "local" của Proxmox (Proxmox tự tải, không đi qua máy bạn).
# Tải một lần; các VM khác có thể dùng lại id của resource này.
resource "proxmox_download_file" "noble" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "sandbox" {
  name            = "tf-sandbox"
  description     = "Managed by Terraform: labs/terraform-basics/07-first-proxmox-vm"
  tags            = ["terraform", "sandbox"]
  node_name       = var.pve_node
  vm_id           = var.vm_id
  stop_on_destroy = true # cloud image chưa có guest agent nên phải stop thay vì shutdown

  agent {
    enabled = false # cloud image chưa có qemu-guest-agent
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.noble.id
    interface    = "scsi0"
    size         = 20
    discard      = "on"
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  # Cloud image cần cổng serial, nếu không thì console trên Proxmox có thể bị trống
  serial_device {}

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    user_account {
      username = "ansible"
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
    }
  }
}
