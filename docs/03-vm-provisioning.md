# Giai đoạn 3: Image + VM bằng code (Packer + Terraform)

Mục tiêu:
1. **Packer** dựng template `ubuntu-2404-base` từ ISO bằng **Ubuntu autoinstall**, hoàn toàn tự động.
2. **Terraform** linked-clone template ra 3 VM với IP tĩnh qua cloud-init, rồi **tự sinh inventory** cho Ansible.

```
ISO 24.04 + user-data ──Packer proxmox-iso──► VM tạm ──generalize──► template 9000
template 9000 ──Terraform clone + cloud-init──► kubec1 / kubew1 / kubew2 ──► hosts.ini
```
Code sẽ nằm ở `infra/packer/ubuntu-base/` và `infra/terraform/vms/`.

---

## Phần A: Packer + autoinstall → template

### A1. Packer là gì, khác Terraform ở đâu?
- Packer **build image** rồi kết thúc, không giữ state và không quản lý vòng đời. Mỗi lần `packer build` tạo ra một artifact mới (ở đây là template Proxmox).
- Terraform **quản lý** tài nguyên đang tồn tại và có state.
- Mô hình chung: Packer làm ra "khuôn", Terraform "đúc" VM từ khuôn đó.

### A2. Đưa autoinstall vào VM: chọn đĩa `cidata`, không dùng HTTP
Có 2 cách để installer đọc được `user-data`:

| Cách | Cơ chế | Với toolbox |
|---|---|---|
| HTTP (`ds=nocloud-net;s=http://...`) | Packer mở HTTP server, VM tải file về qua mạng | VM phải gọi **ngược vào control node**: phải mở port trên host, và Packer dễ đoán sai IP |
| **CD `cidata`** (`ds=nocloud`) | Packer đóng `user-data` + `meta-data` thành ISO có label `cidata`, gắn vào VM như ổ CD | Không cần kết nối ngược về control node ✅ |

Lab này dùng **CD `cidata`**. Cách này cần `xorriso`, đã có sẵn trong toolbox.

### A3. `http/user-data`: những phần quan trọng
Nếu bạn đã có `user-data` từ autoinstall generator, hãy dùng lại và đối chiếu với các điểm dưới đây:

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  timezone: Asia/Ho_Chi_Minh
  source:
    id: ubuntu-server-minimal        # image gọn, đủ cho node K8s
  network:
    version: 2
    ethernets:
      any:
        match:
          name: "en*"
        dhcp4: true                  # chỉ dùng DHCP lúc build, clone sẽ nhận IP tĩnh từ cloud-init
  storage:
    swap:
      size: 0                        # kubelet yêu cầu không có swap
    layout:
      name: lvm
      sizing-policy: all
  identity:
    hostname: ubuntu-base
    username: ansible
    password: "$6$..."               # mkpasswd -m sha-512; chỉ để login console khi cứu hộ
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "ssh-ed25519 AAAA... k8s-lab"   # nội dung ~/.ssh/k8s_lab.pub
  packages:
    - qemu-guest-agent
    - python3                        # Ansible cần
  updates: security
  late-commands:
    - "echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-ansible"
    - "chmod 0440 /target/etc/sudoers.d/90-ansible"
    - "curtin in-target --target=/target -- systemctl enable qemu-guest-agent"
```
File `http/meta-data` để **rỗng**, nhưng vẫn bắt buộc phải có.

> **Vì sao không xoá cấu hình cloud-init của installer ngay trong `late-commands`?**
> Subiquity ghi user, SSH key và hostname vào `/etc/cloud/cloud.cfg.d/99-installer.cfg` (datasource `None`), để cloud-init **tạo user ở lần boot đầu tiên**. Xoá file đó trong `late-commands` thì user `ansible` sẽ không được tạo, và Packer không SSH vào được. Vì vậy ta để lần boot đầu chạy xong rồi mới dọn dẹp ở bước generalize (A5).

### A4. `ubuntu-base.pkr.hcl`: phần chính
```hcl
packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

source "proxmox-iso" "ubuntu" {
  # Kết nối: đọc PROXMOX_URL / PROXMOX_USERNAME / PROXMOX_TOKEN từ env
  node                     = "homelab"
  insecure_skip_tls_verify = true

  vm_id                = 9000
  vm_name              = "ubuntu-2404-base"
  template_description = "Ubuntu 24.04 base, built by Packer ${timestamp()}"

  boot_iso {
    type     = "ide"
    index    = 2
    iso_file = "local:iso/ubuntu-24.04.X-live-server-amd64.iso"
    unmount  = true
  }
  additional_iso_files {
    type             = "ide"
    index            = 3
    cd_files         = ["./http/user-data", "./http/meta-data"]
    cd_label         = "cidata"
    iso_storage_pool = "local"
    unmount          = true
  }

  os              = "l26"
  cpu_type        = "host"
  cores           = 2
  memory          = 2048
  qemu_agent      = true
  scsi_controller = "virtio-scsi-single"

  disks {
    type         = "scsi"
    disk_size    = "20G"
    storage_pool = "local-lvm"
    format       = "raw"
  }
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  cloud_init              = true          # gắn sẵn ổ cloud-init cho template
  cloud_init_storage_pool = "local-lvm"

  boot_wait = "10s"
  boot_command = [
    "<wait>e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud",
    "<f10>"
  ]

  ssh_username           = "ansible"
  ssh_private_key_file   = pathexpand("~/.ssh/k8s_lab")
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 100
}
```
Những điểm cần hiểu:
- `boot_command` mô phỏng thao tác bàn phím ở menu GRUB: `e` để sửa entry, nhảy xuống dòng `linux`, thêm `autoinstall ds=nocloud`, rồi `F10` để boot. Có tham số `autoinstall` thì installer **không hỏi xác nhận** nữa.
- `ssh_handshake_attempts = 100`: trong lúc cài, môi trường live installer cũng mở SSH. Packer sẽ thử đăng nhập bằng user `ansible`, thất bại và thử lại liên tục cho đến khi máy reboot vào hệ thống đã cài. Để giá trị này thấp thì Packer sẽ bỏ cuộc giữa chừng.
- Tên field thay đổi theo version plugin. Ví dụ trước v1.2, `iso_file` nằm ở cấp ngoài cùng chứ không trong `boot_iso`. Hãy tra docs đúng version bạn đang dùng.

### A5. Generalize: biến VM thành "khuôn" sạch
```hcl
build {
  sources = ["source.proxmox-iso.ubuntu"]

  provisioner "shell" {
    inline = [
      "cloud-init status --wait",            # chờ lần boot đầu xong (đã tạo user, xong apt)
      # 1. Bỏ cấu hình của installer để cloud-init đọc được ổ cloud-init của Proxmox
      "sudo rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg /etc/cloud/cloud.cfg.d/90-installer-network.cfg /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
      "echo 'datasource_list: [ NoCloud, ConfigDrive ]' | sudo tee /etc/cloud/cloud.cfg.d/99-pve.cfg",
      "sudo rm -f /etc/netplan/*.yaml",      # cloud-init sẽ sinh lại netplan với IP tĩnh
      # 2. Xoá danh tính của máy
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo apt-get clean",
      "sync"
    ]
  }
}
```
| Bỏ bước | Hậu quả trên các clone |
|---|---|
| Không xoá `99-installer.cfg` | cloud-init dùng datasource `None`, bỏ qua IP/hostname/key mà Terraform truyền vào |
| Không xoá netplan cũ | clone vẫn chạy DHCP song song với IP tĩnh, hoặc giữ cấu hình cũ |
| Không `cloud-init clean` | cloud-init tưởng đã chạy rồi nên không cấu hình lại |
| Không xoá `machine-id` | các clone **trùng machine-id**, dẫn tới pfSense cấp trùng IP DHCP, và K8s node có `systemUUID` lạ |

### A6. Build
```bash
cd infra/packer/ubuntu-base
packer init .
packer fmt . && packer validate .
packer build .
```
Trong lúc build, mở **Console** của VM 9000 trên giao diện Proxmox để xem installer chạy. Lần đầu nên xem từ đầu đến cuối, rất đáng.

Kiểm tra sau khi build: VM 9000 hiện biểu tượng template, tab **Hardware** có `CloudInit Drive`.

---

## Phần B: Terraform clone ra node

### B1. Biến `nodes`: một nguồn sự thật duy nhất
```hcl
# terraform.tfvars (copy từ terraform.tfvars.example)
pve_node    = "homelab"
template_id = 9000
gateway     = "10.10.10.254"
dns_servers = ["10.10.10.254"]     # pfSense: phân giải được k8s-api.hainth.local (Host Override)
ssh_public_key_file = "~/.ssh/k8s_lab.pub"

nodes = {
  "kubec1" = { vm_id = 151, role = "control_plane", ip = "10.10.10.51", cores = 2, memory = 3072, disk = 30 }
  "kubew1"  = { vm_id = 161, role = "worker",        ip = "10.10.10.61", cores = 2, memory = 3072, disk = 30 }
  "kubew2"  = { vm_id = 162, role = "worker",        ip = "10.10.10.62", cores = 2, memory = 3072, disk = 30 }
}
```
Thêm, bớt hay đổi cấu hình node đều chỉ cần **sửa đúng chỗ này**.

### B2. Module `k8s-node`: phần chính
```hcl
resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  node_name       = var.pve_node
  vm_id           = var.vm_id
  tags            = ["k8s", var.role]
  on_boot         = true             # tự bật khi Proxmox khởi động lại
  stop_on_destroy = true

  clone {
    vm_id = var.template_id
    full  = false                    # linked clone: nhanh, tiết kiệm disk
  }

  agent {
    enabled = true
  }
  cpu {
    cores = var.cores
    type  = "host"
  }
  memory {
    dedicated = var.memory
    floating  = 0                    # tắt ballooning: kubelet tính allocatable lúc khởi động, RAM co giãn sẽ gây lệch
  }
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.disk          # >= kích thước disk template (20G)
  }
  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = var.gateway
      }
    }
    dns {
      domain  = "hainth.local"         # search domain → systemd-resolved gửi *.hainth.local tới pfSense
      servers = var.dns_servers
    }
    user_account {
      username = "ansible"
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
    }
  }
}
```

### B3. Sinh inventory
```hcl
# main.tf (root)
module "node" {
  source   = "./modules/k8s-node"
  for_each = var.nodes
  name     = each.key
  vm_id    = each.value.vm_id
  # ... các biến khác
}

resource "local_file" "inventory" {
  filename        = "${path.root}/../../../ansible/inventory/hosts.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.tftpl", {
    nodes = var.nodes
  })
}
```
Đây chính là bài 5 của giai đoạn 1, chỉ khác là áp vào VM thật.

### B4. Chạy
```bash
cd infra/terraform/vms
terraform init
terraform plan -out tf.plan     # đọc kỹ: phải là "3 to add"
terraform apply tf.plan
rm -f ~/.ssh/known_hosts_lab    # host key mới sau mỗi lần dựng lại
cd ../../../ansible && ansible all -m ping
```

---

## Phần C: Phương án so sánh: cloud image (không cần Packer)
Ở bài 7 của giai đoạn 1 bạn đã import thẳng **cloud image** của Ubuntu. Hai cách khác nhau như sau:

| | Packer + autoinstall (ISO) | Cloud image |
|---|---|---|
| Thời gian chuẩn bị | Build mất 10–20 phút một lần | Tải file là xong |
| Kiểm soát | Toàn quyền: partition/LVM, package, bản minimal | Theo layout Canonical đóng sẵn |
| Giống production | Giống quy trình build image của doanh nghiệp | Giống cách làm trên cloud public |
| Mở rộng | Bake thêm phần mềm (giai đoạn 8) | Phải cấu hình sau khi boot |

Bài tập: dựng `kubew2` từ cloud image, giữ 2 node còn lại từ template, rồi so sánh thời gian từ `apply` đến khi `ansible ping` được.

---

## Bài tập
1. Build template, rồi xem file `/etc/cloud/cloud.cfg.d/` trên một clone. Giải thích từng file còn lại.
2. Chạy `terraform plan` lần 2 sau khi `apply`. Kết quả phải là `No changes`. Nếu vẫn có thay đổi (*perpetual diff*), hãy tìm attribute gây ra và tìm cách xử lý (dùng `lifecycle.ignore_changes`, hoặc khai báo giá trị khớp với mặc định của Proxmox).
3. Thêm `kubew3` vào `nodes` → `plan` phải là `1 to add` → `apply` → `hosts.ini` tự cập nhật.
4. Đổi `memory` của `kubew1` → `plan` là sửa tại chỗ hay tạo lại? VM có cần reboot không?
5. `terraform state rm module.node["kubew3"]` → `plan` báo gì? Dùng khối `import {}` để đưa `kubew3` vào lại state.
6. Kiểm tra `cat /etc/machine-id` trên 3 VM. Cả 3 phải khác nhau.

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| Packer kẹt ở `Waiting for SSH` quá lâu | Mở console VM 9000. Nếu installer đang hỏi gì đó: `user-data` sai cú pháp hoặc thiếu `autoinstall` trong cmdline. Nếu đã cài xong mà vẫn không SSH được: sai key hoặc VM chưa nhận DHCP |
| Installer bỏ qua `user-data` | File phải bắt đầu đúng bằng `#cloud-config`, ISO phải có label `cidata`, phải có cả file `meta-data` |
| Clone không nhận IP tĩnh | Bước A5 chưa chạy hoặc lỗi. Kiểm tra `/etc/cloud/cloud.cfg.d/99-installer.cfg` có còn không, và `cloud-init status --long` |
| `403` khi clone hoặc tạo disk | Role thiếu privilege (thường là `Datastore.AllocateSpace` hoặc `VM.Clone`), xem giai đoạn 0, bước B6 |
| `terraform destroy` treo | Guest agent chưa chạy. Đặt `stop_on_destroy = true`, hoặc stop VM trên giao diện |
| `ansible ping` báo `Host key verification failed` | Xoá `~/.ssh/known_hosts_lab` |

➡️ Tiếp theo: [04: Bootstrap Kubernetes](04-bootstrap-kubernetes.md)
