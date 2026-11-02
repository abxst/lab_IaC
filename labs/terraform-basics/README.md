# Lab: Terraform cơ bản (Giai đoạn 1)

Lý thuyết và đề bài nằm ở [docs/01-terraform-basics.md](../../docs/01-terraform-basics.md). Thư mục này là **code mẫu để đối chiếu**. Hãy tự gõ lại trước, rồi mới mở code ra so sánh.

| Bài | Thư mục | Cần hạ tầng? |
|---|---|---|
| 1 | [01-hello](01-hello/) | Không |
| 2 | [02-variables](02-variables/) | Không |
| 3 | [03-for-each](03-for-each/) | Không |
| 4 | [04-random-and-deps](04-random-and-deps/) | Không |
| 5 | [05-templatefile](05-templatefile/) | Không |
| 6 | [06-modules](06-modules/) | Không |
| 7 | [07-first-proxmox-vm](07-first-proxmox-vm/) | **Có**: Proxmox + `.envrc` (giai đoạn 0) |

## Quy trình cho mọi bài

Chạy trong WSL trên Jump, thư mục `~/devopvips` (xem [docs/00-setup.md, Phần C](../../docs/00-setup.md)):
```bash
cd labs/terraform-basics/01-hello
terraform init
terraform fmt -check && terraform validate
terraform plan
terraform apply
# ... làm các thí nghiệm trong docs ...
terraform destroy
```

Mỗi bài có state riêng (`terraform.tfstate` nằm ngay trong thư mục bài). File state và thư mục `out/` đã được đưa vào `.gitignore`.

## Version

| Thành phần | Version pin |
|---|---|
| Terraform | `>= 1.9` (đã kiểm tra với 1.17.1) |
| hashicorp/local | `~> 2.9` |
| hashicorp/random | `~> 3.9` |
| bpg/proxmox | `~> 0.119.0` |

> Provider đang ở `0.x` thì bản minor mới có thể đổi tên field. Vì vậy `bpg/proxmox` được pin tới **patch** (`~> 0.119.0`). Khi nâng version, hãy đọc changelog trước.
