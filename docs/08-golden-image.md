# Giai đoạn 8 (nâng cao): Golden image với Packer + Ansible

Mục tiêu: bake sẵn containerd, kubeadm/kubelet và image của control plane vào template. Node mới boot lên là gần như sẵn sàng `join` ngay. Từ đó ta chuyển sang tư duy **immutable infrastructure**: không sửa node đang chạy, mà thay bằng node mới.

```
ubuntu-2404-base (9000) ──Packer proxmox-clone + Ansible──► ubuntu-2404-k8s-v1-36 (9136)
                                                         ► ubuntu-2404-k8s-v1-37 (9137) ...
Terraform: nodes[*].template_id = 9136 | 9137
```
Code sẽ nằm ở `infra/packer/ubuntu-k8s/` và `ansible/playbooks/bake-image.yml`.

---

## 1. Bake hay fry?

| | **Bake** (đưa vào image) | **Fry** (làm lúc chạy) |
|---|---|---|
| Ví dụ | package, kernel module, sysctl, containerd, kubeadm/kubelet, image `pause`/`etcd`/`kube-*` pre-pull | hostname, IP, `/etc/hosts`, `kubeadm init/join`, token, cert, label |
| Ưu điểm | boot nhanh, mọi node giống hệt nhau, không phụ thuộc mạng lúc dựng | linh hoạt, một image dùng được cho nhiều mục đích |
| Nhược điểm | đổi bất kỳ thứ gì cũng phải build lại image | chậm, dễ "trôi" cấu hình (drift) giữa các node |

Quy tắc: **cái gì giống nhau trên mọi node thì bake, cái gì là danh tính hoặc bí mật thì fry.** Không bao giờ bake token, cert hay private key vào image.

## 2. Dùng lại role Ansible
Ta **không viết lại** script cài đặt cho Packer. Packer gọi Ansible với **chính các role** `common`, `containerd`, `kube_packages` của giai đoạn 4. Image và node chạy cùng một code, nên không có chuyện "image cài khác, node cài khác".

Muốn vậy, role phải phân biệt được lúc bake và lúc chạy:
```yaml
# roles/common/tasks/main.yml
- name: Đặt hostname
  ansible.builtin.hostname:
    name: "{{ inventory_hostname }}"
  when: not (image_bake | default(false))     # danh tính: không bake

- name: Kernel modules + sysctl
  ansible.builtin.import_tasks: kernel.yml     # giống nhau: bake
```
```yaml
# playbooks/bake-image.yml
- hosts: all
  become: true
  vars:
    image_bake: true
  roles: [common, containerd, kube_packages]
  post_tasks:
    - name: Pre-pull image control plane
      ansible.builtin.command: kubeadm config images pull --kubernetes-version v{{ k8s_version }}
      changed_when: true
```

## 3. Packer template
```hcl
variable "k8s_version" {
  type = string                         # "1.36.X"
}

locals {
  k8s_minor_dash = join("-", slice(split(".", var.k8s_version), 0, 2))   # "1-36"
}

source "proxmox-clone" "k8s" {
  node                     = "homelab"
  insecure_skip_tls_verify = true
  clone_vm_id              = 9000
  full_clone               = true
  vm_id                    = 9100 + tonumber(split(".", var.k8s_version)[1])   # 1.36 → 9136
  vm_name                  = "ubuntu-2404-k8s-v${local.k8s_minor_dash}"       # tên VM không được chứa dấu chấm
  template_description     = "K8s v${var.k8s_version}, built ${timestamp()}"

  cores  = 2
  memory = 2048
  ipconfig {
    ip = "dhcp"                         # chỉ dùng DHCP trong lúc build
  }
  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  ssh_username         = "ansible"
  ssh_private_key_file = pathexpand("~/.ssh/k8s_lab")
}

build {
  sources = ["source.proxmox-clone.k8s"]

  provisioner "ansible" {
    playbook_file    = "${path.root}/../../../ansible/playbooks/bake-image.yml"
    user             = "ansible"
    extra_arguments  = ["-e", "k8s_version=${var.k8s_version}"]
    ansible_env_vars = ["ANSIBLE_ROLES_PATH=${path.root}/../../../ansible/roles"]
  }

  provisioner "shell" {
    inline = [
      # generalize lại, giống giai đoạn 3 bước A5
      "sudo rm -f /etc/netplan/*.yaml",
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo apt-get clean",
      "sync"
    ]
  }
}
```
Bạn cần thêm plugin `ansible` vào `required_plugins`.
```bash
cd infra/packer/ubuntu-k8s
packer init . && packer validate -var k8s_version=1.36.X .
packer build -var k8s_version=1.36.X .
```

## 4. Terraform chọn template theo từng node
```hcl
variable "default_template_id" {
  type    = number
  default = 9136
}

# mỗi node có thể ghi đè template_id riêng → dùng cho rolling replace
nodes = {
  "kubew1" = { vm_id = 161, role = "worker", ip = "10.10.10.61", template_id = 9136, ... }
  "kubew4" = { vm_id = 164, role = "worker", ip = "10.10.10.64", template_id = 9137, ... }
}
```
Trong module, dùng `coalesce(each.value.template_id, var.default_template_id)` hoặc khai báo attribute `optional()`.

## 5. Upgrade theo kiểu immutable (cho worker)
> Cluster HA stacked của giai đoạn 7 không có worker riêng. Phần này làm trên topo 1 control-plane + worker: dựng lại bằng tfvars của giai đoạn 4, hoặc thêm 1 worker tạm. Lưu ý RAM: mỗi lần chỉ có thêm **1 node mới** cùng lúc, tạo xong node mới thì xoá ngay node cũ.

Thay vì nâng gói tại chỗ trên node như giai đoạn 6:
```
1. packer build -var k8s_version=1.37.X           → template 9137
2. upgrade control plane như giai đoạn 6           (control plane vẫn upgrade tại chỗ, xem lý do bên dưới)
3. thêm kubew4 dùng 9137 → apply → join             (node mới đã có sẵn bản 1.37)
4. remove-node.yml kubew1 → xoá khỏi tfvars → apply
5. lặp lại với từng worker còn lại
```
> Vì sao control plane thường vẫn được upgrade tại chỗ? Thay control-plane nghĩa là thay member etcd và thao tác với quorum, rủi ro cao hơn nhiều. Các nền tảng như Cluster API làm được việc này nhờ tự động hoá rất kỹ. Trong lab, thay worker là đủ để hiểu nguyên lý.

## 6. Vệ sinh image
- Đặt tên và VMID theo version. Chỉ giữ 2 bản gần nhất, xoá bản cũ bằng `qm destroy <id>` sau khi đã chắc chắn không còn node nào dùng.
  - **Lưu ý:** template đang có linked clone thì **không xoá được**. Đây là lý do nên dùng full clone cho template, hoặc thay hết node trước khi xoá template.
- Ghi thông tin build vào `template_description`: version K8s, containerd, ngày build, git commit.
- Build lại image định kỳ, ví dụ mỗi tháng, để có các bản vá bảo mật mới của OS.

---

## 7. Bài tập
1. Đo thời gian `make up` với image base (giai đoạn 3) và với golden image. Ghi lại từng chặng: `terraform apply`, `site.yml`, đến khi node `Ready`.
2. Chạy `site.yml` trên node dựng từ golden image. Các task bake phải ra `ok`, không có `changed`. Đây là bằng chứng image và role khớp nhau.
3. Thực hiện upgrade theo kiểu immutable cho 2 worker (mục 5). Vừa làm vừa chạy `curl` liên tục để chứng minh không gián đoạn.
4. Viết target `make image K8S=1.37.X` trong `Makefile`.
5. Thảo luận: nên bake image Calico không? Có lợi gì, và có rủi ro gì về version (CNI do operator quản lý)?

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| Packer `proxmox-clone` không SSH được | Template base không có netplan nên phải có `ipconfig { ip = "dhcp" }`, và template phải có ổ cloud-init |
| `vm_name` bị Proxmox từ chối | Tên phải hợp lệ như tên DNS: không có dấu chấm, không có dấu gạch dưới |
| Ansible trong Packer không tìm thấy role | Đặt `ANSIBLE_ROLES_PATH` hoặc trỏ `ANSIBLE_CONFIG` tới `ansible/ansible.cfg` |
| Node từ golden image vẫn tự cài lại gói | Version trong image khác `k8s_version` trong `group_vars`. Cả hai phải dùng chung một nguồn |

⬅️ Quay lại [README](../README.md)
