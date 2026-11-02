# Giai đoạn 1: Terraform cơ bản

Mục tiêu: hiểu cách Terraform "nghĩ", trước khi cho nó chạm vào hạ tầng thật. Các bài 1–6 chỉ dùng provider `local`, `random` và `terraform_data`, nên không tốn tài nguyên và có thể phá thoải mái. Bài 7 tạo VM đầu tiên trên Proxmox.

Code sẽ nằm ở `labs/terraform-basics/0X-*/`. Hãy **tự gõ lại** từng bài trước khi mở code mẫu.

---

## 1. Khái niệm cốt lõi

### Infrastructure as Code: khai báo, không phải ra lệnh
Script bash là **mệnh lệnh** ("tạo VM, rồi gán IP, rồi..."). Terraform là **khai báo**: bạn mô tả *trạng thái mong muốn* ("phải có 3 VM với cấu hình này"), Terraform tự tính ra cần làm gì để đạt được trạng thái đó.

```
code (.tf)  ──┐
              ├──► terraform plan  ──► diff (+ tạo / ~ sửa / - xoá / -/+ tạo lại)
state       ──┤                         │
thực tế     ──┘                         ▼
                                  terraform apply  ──► gọi API ──► cập nhật state
```

### Các khối xây dựng

| Khối | Vai trò | Ví dụ |
|---|---|---|
| `terraform {}` | version Terraform + provider cần dùng | `required_providers { proxmox = { source = "bpg/proxmox" } }` |
| `provider` | cấu hình kết nối tới một API | endpoint Proxmox, kubeconfig |
| `resource` | thứ Terraform **tạo và quản lý** | VM, file, helm release |
| `data` | thứ Terraform **chỉ đọc**, không quản lý | đọc template có sẵn, đọc file |
| `variable` | đầu vào | `var.nodes` |
| `locals` | biến tính toán nội bộ | `local.cp_nodes` |
| `output` | đầu ra (in ra màn hình hoặc cho module khác dùng) | IP các node |
| `module` | gói tái sử dụng (một thư mục `.tf`) | `module "node" { source = "./modules/k8s-node" }` |

### State: trái tim của Terraform
- `terraform.tfstate` là "trí nhớ": resource `X` trong code tương ứng với object `ID=123` ngoài thực tế.
- Mất state thì Terraform "quên" hạ tầng: lần apply sau nó sẽ tạo trùng.
- State có thể chứa **secret ở dạng plain text**, nên **không bao giờ commit lên git** (đã có trong `.gitignore`).
- Khi làm nhóm, state được để ở backend dùng chung (S3, Terraform Cloud, PostgreSQL...) và có khoá (lock). Lab này dùng state local.

### Vòng đời lệnh
```bash
terraform init       # tải provider, khởi tạo backend (chạy lại khi thêm provider/module)
terraform fmt        # format code
terraform validate   # kiểm tra cú pháp + kiểu dữ liệu
terraform plan       # xem trước thay đổi, LUÔN đọc kỹ trước khi apply
terraform apply      # thực thi
terraform destroy    # xoá mọi thứ trong state
terraform console    # REPL để thử biểu thức, rất tiện khi học
terraform state list / show <addr>   # soi state
```

### Đồ thị phụ thuộc
Terraform tự suy ra thứ tự thực hiện từ **tham chiếu**: nếu resource B dùng `aws_x.a.id` thì A được tạo trước. Bạn chỉ dùng `depends_on` khi có phụ thuộc "ẩn" mà Terraform không nhìn thấy được qua tham chiếu.

### `count` và `for_each`
```hcl
# count: định danh bằng số, kiểu node[0], node[1]
resource "local_file" "a" {
  count    = 3
  filename = "node-${count.index}.txt"
  content  = "x"
}

# for_each: định danh bằng key, kiểu node["kubew1"]  ← DÙNG CÁI NÀY cho node
resource "local_file" "b" {
  for_each = { "kubec1" = "10.0.0.51", "kubew1" = "10.0.0.61" }
  filename = "${each.key}.txt"
  content  = each.value
}
```
> Với `count`, xoá phần tử ở giữa list làm **các phần tử phía sau bị đánh số lại**, nên Terraform sẽ xoá và tạo lại chúng. Với VM, điều đó nghĩa là **mất node**. `for_each` theo key thì không bị vấn đề này.

### Các biểu thức hay dùng
```hcl
locals {
  workers   = { for k, v in var.nodes : k => v if v.role == "worker" }   # lọc map
  all_ips   = [for n in values(var.nodes) : n.ip]                        # map -> list
  inventory = templatefile("${path.module}/inventory.tftpl", { nodes = var.nodes })
}
```

### `lifecycle`
```hcl
lifecycle {
  prevent_destroy       = true          # chặn lỡ tay destroy
  ignore_changes        = [description] # bỏ qua thay đổi được làm từ bên ngoài
  create_before_destroy = true          # tạo cái mới trước, xoá cái cũ sau
}
```

---

## 2. Bài tập

Mỗi bài là một thư mục riêng, có state riêng. Quy trình chuẩn cho mọi bài: `init → fmt → validate → plan → apply → (sửa) → plan → destroy`.

### Bài 1: `01-hello`: resource đầu tiên và state
- Tạo một `local_file` ghi `hello.txt`.
- Sau khi `apply`, mở `terraform.tfstate` ra đọc.
- **Thí nghiệm:**
  1. Sửa nội dung file **bằng tay**, rồi chạy `plan`. Terraform phát hiện ra *drift* và muốn ghi đè lại.
  2. Xoá file bằng tay, rồi `plan`.
  3. Đổi `content` trong code, rồi `plan`. Để ý ký hiệu `-/+` (tạo lại) so với `~` (sửa tại chỗ).
- ❓ Vì sao `local_file` bị *tạo lại* khi đổi content chứ không *sửa tại chỗ*? (Gợi ý: tìm chữ "forces replacement" trong output của plan.)

### Bài 2: `02-variables`: variable, validation, output, tfvars
- Khai báo `variable "env"` kiểu `string`, có `validation` chỉ cho phép `lab` hoặc `prod`.
- Truyền giá trị theo 3 cách: `-var`, file `terraform.tfvars`, biến môi trường `TF_VAR_env`. Thử xem cách nào thắng khi đặt cả ba.
- Thêm `output` và thử `terraform output -json`.
- Đánh dấu một biến là `sensitive = true` và xem nó hiển thị thế nào trong plan và trong state.
- ❓ `sensitive` có làm giá trị biến mất khỏi state không?

### Bài 3: `03-for-each`: tạo nhiều resource từ một map
- `variable "nodes"` có kiểu:
  ```hcl
  map(object({ role = string, ip = string, cores = number, memory = number }))
  ```
- Tạo mỗi node một file `<name>.txt`.
- Thêm một node, xoá một node ở giữa, rồi `plan`. Ghi lại xem có node nào khác bị ảnh hưởng không.
- Viết lại bằng `count` và lặp lại thí nghiệm. So sánh kết quả.

### Bài 4: `04-random-and-deps`: phụ thuộc và `random`
- `random_pet` sinh tên cluster, `random_password` sinh token.
- Dùng tên đó trong một `local_file`. Xem Terraform tự sắp thứ tự qua `terraform graph` (có thể dán output vào https://dreampuf.github.io/GraphvizOnline).
- Dùng `keepers` (random) hoặc `triggers_replace` (`terraform_data`) để buộc sinh lại giá trị khi một input thay đổi.

### Bài 5: `05-templatefile`: sinh file cấu hình (bài **quan trọng nhất**)
Từ biến `nodes` ở bài 3, sinh file `inventory.ini` theo định dạng Ansible:
```ini
[control_plane]
kubec1 ansible_host=10.10.10.51

[workers]
kubew1 ansible_host=10.10.10.61
kubew2 ansible_host=10.10.10.62

[k8s_cluster:children]
control_plane
workers
```
File `inventory.tftpl` gợi ý:
```
[control_plane]
%{ for name, n in nodes ~}
%{ if n.role == "control_plane" ~}
${name} ansible_host=${n.ip}
%{ endif ~}
%{ endfor ~}
```
- ❓ Dấu `~` trong `%{ ... ~}` dùng để làm gì? Thử bỏ nó đi rồi xem file sinh ra khác thế nào.
- Mở rộng: dùng `jsonencode`/`yamlencode` để sinh thêm `nodes.yml`.

Pattern này sẽ được dùng lại y nguyên ở giai đoạn 3.

### Bài 6: `06-modules`: đóng gói thành module
- Tách logic "một node, một file" thành `modules/node/` với `variables.tf`, `main.tf`, `outputs.tf`.
- Root module gọi `module "node" { for_each = var.nodes ... }`.
- Gom output của tất cả module thành một map `name => ip`.
- Đổi tên một resource *bên trong* module, rồi dùng khối `moved {}` để Terraform không xoá và tạo lại resource đó.
- ❓ Khi nào nên tách module, khi nào thì không nên? Nguyên tắc chung: chỉ tách khi có ít nhất 2 chỗ dùng, hoặc khi phần đó có ranh giới rõ ràng.

### Bài 7 (bonus): `07-first-proxmox-vm`: VM thật đầu tiên
Yêu cầu: đã xong giai đoạn 0 (có `.envrc` với `PROXMOX_VE_*`).

Mục tiêu là làm quen provider `bpg/proxmox`, **chưa cần** template hay Packer. Ta dùng Ubuntu **cloud image**, là bản đã cài sẵn OS:
```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.119.0" # bản đã kiểm tra; xem bản mới nhất trên registry
    }
  }
}
provider "proxmox" {}   # đọc PROXMOX_VE_ENDPOINT / _API_TOKEN / _INSECURE / _SSH_* từ env

resource "proxmox_download_file" "noble" {
  node_name    = "homelab"
  datastore_id = "local"
  content_type = "import"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
}

resource "proxmox_virtual_environment_vm" "sandbox" {
  name      = "tf-sandbox"
  node_name = "homelab"
  vm_id     = 199
  agent {
    enabled = false                  # cloud image chưa có qemu-guest-agent
  }
  cpu {
    cores = 2
    type  = "host"
  }
  memory {
    dedicated = 2048
  }
  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.noble.id
    interface    = "scsi0"
    size         = 20
  }
  network_device {
    bridge = "vmbr0"
  }
  initialization {
    ip_config {
      ipv4 {
        address = "10.10.10.59/24"
        gateway = "10.10.10.254"
      }
    }
    user_account {
      username = "ansible"
      keys     = [trimspace(file("~/.ssh/k8s_lab.pub"))]
    }
  }
}
```
- Sau `apply`: `ssh ansible@10.10.10.59`.
- Mở giao diện Proxmox, tab **Cloud-Init** của VM, xem Terraform đã điền những gì.
- Đổi `memory` rồi `plan`: sửa tại chỗ. Đổi `vm_id` rồi `plan`: tạo lại. Hiểu vì sao hai thay đổi này khác nhau.
- **Giữ VM này lại** để làm giai đoạn 2. Khi xong giai đoạn 2 thì `destroy`.

> Tên field có thể thay đổi giữa các version provider (ví dụ `import_from` trước đây là `file_id`). Khi `validate` báo lỗi, hãy tra **docs đúng version** đang pin trên registry, không tra theo blog cũ.

---

## 3. Tự kiểm tra

Trả lời được hết các câu sau mới sang giai đoạn 2:
1. `plan` hiện `-/+` nghĩa là gì? Vì sao điều đó nguy hiểm với VM đang chạy?
2. Bạn lỡ xoá `terraform.tfstate` của bài 7, chuyện gì xảy ra khi `apply` lại? Làm sao cứu được? (Gợi ý: khối `import {}` hoặc lệnh `terraform import`.)
3. Khác nhau giữa `resource` và `data`?
4. Vì sao nên dùng `for_each` theo map cho node, thay vì `count`?
5. Tại sao không commit `*.tfstate` và `*.tfvars`?

## Tài liệu đọc thêm
- https://developer.hashicorp.com/terraform/tutorials/configuration-language
- https://developer.hashicorp.com/terraform/language/expressions
- https://registry.terraform.io/providers/bpg/proxmox/latest/docs

➡️ Tiếp theo: [02: Ansible cơ bản](02-ansible-basics.md)
