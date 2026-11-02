# Toolbox: control node của lab

Một container Ubuntu 24.04 có đủ công cụ, chạy trên host Dokploy (`super-nginx`, `10.10.10.201`):

| Tool | Version |
|---|---|
| Terraform | 1.17.1 |
| Packer | 1.16.2 |
| Ansible / ansible-core | 14.5.0 / 2.21 |
| ansible-lint | 26.10.1 |
| kubectl | v1.36.6 (cluster lab chạy 1.36) |
| Helm | v4.3.1 |

Version được pin bằng `ARG` trong [Dockerfile](Dockerfile). Image do GitHub Actions ([toolbox-image.yml](../.github/workflows/toolbox-image.yml)) build mỗi khi `toolbox/` thay đổi, rồi đẩy lên `ghcr.io/abxst/lab_iac/toolbox` (tag `latest` và `sha-xxxxxxx`). Trên host chỉ cần `docker compose pull && docker compose up -d`.

Cách cài, cách dùng hằng ngày và cách xử lý lỗi xem ở [docs/00-setup.md, Phần C](../docs/00-setup.md#phần-c-toolbox-container-trên-dokploy-control-node).

```
host super-nginx
└─ /opt/devops-toolbox/home  ──bind mount──►  /home/devops (trong container)
     ├─ devopvips/            repo (git clone) + terraform.tfstate của từng thư mục
     ├─ .ssh/                 k8s_lab, k8s_lab.pub, config
     ├─ .kube/                k8s-lab.conf
     └─ .terraform.d/         cache provider
```
**Backup thư mục `/opt/devops-toolbox/home`.** Image có thể build lại bất cứ lúc nào, còn dữ liệu trong thư mục này thì không tạo lại được. File state, `.envrc` và key đều nằm trong `.gitignore`, nên `git pull` không đụng tới chúng.
