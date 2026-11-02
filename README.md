# DevOps Lab: Terraform + Ansible → Kubernetes trên Proxmox

Lộ trình tự học **Terraform**, **Ansible** (và **Packer**) bằng cách tự động hóa toàn bộ vòng đời một cluster Kubernetes thật trên homelab Proxmox: dựng image, tạo VM, cài cluster, cài add-on, vận hành Day-2, nâng lên HA.

> Trạng thái: **tài liệu đã có cho mọi giai đoạn, code sẽ được thêm dần theo từng giai đoạn.**

## Mục tiêu cuối cùng

```bash
make up        # Packer template → Terraform VM → Ansible kubeadm → Terraform add-on
kubectl get nodes
make destroy   # xoá sạch, dựng lại bất cứ lúc nào
```

## Kiến trúc lab

```
Laptop chính (nơi viết code) ──git push──► GitHub (private)
      │                                        │ git pull
      └──Tailscale──► RDP vào Jump             │
                        │ VS Code Remote-SSH   │
LAN pfSense 10.10.10.0/24 (gateway, DHCP, DNS = pfSense 10.10.10.254)
 │                      ▼                      ▼
 ├─ super-nginx 10.10.10.201 (host Dokploy)
 │    └─ container "toolbox" = CONTROL NODE   (toolbox/, docker compose)
 │         terraform · packer · ansible · kubectl · helm
 │           │  Proxmox API (token)          │ SSH
 │           ▼                               ▼
 └─ Laptop phụ (32GB RAM) = PROXMOX VE "homelab" (10.10.10.1, uplink Wi-Fi ra mạng nhà)
      ├─ template ubuntu-2404-base  (VMID 9000, do Packer + autoinstall tạo)
      ├─ kubec1   10.10.10.51      ┐
      ├─ kubew1   10.10.10.61      ├─ Giai đoạn 3–6   (mỗi node 2 vCPU / 3 GB)
      ├─ kubew2   10.10.10.62      ┘
      ├─ kubec2/kubec3 .52/.53 + VIP .50   ← Giai đoạn 7: thay kubew1/kubew2, 3 control-plane chạy cả workload
      ├─ MetalLB pool .80–.99            ← Giai đoạn 5
      └─ (có sẵn) pfSense, Jump, Dokploy ≈ 16 GB → K8s được tối đa ~9 GB
```

Luồng dữ liệu giữa các công cụ:

```
Packer ──(ISO + autoinstall)──► VM template
Terraform ──(clone + cloud-init)──► VM có IP tĩnh ──(templatefile)──► ansible/inventory/hosts.ini
Ansible ──(SSH)──► containerd + kubeadm ──► cluster ──► ~/.kube/config
Terraform (helm provider) ──(kubeconfig)──► MetalLB, metrics-server, Traefik
```

## Lộ trình

| # | Giai đoạn | Học được gì | Tài liệu | Thời gian* |
|---|-----------|-------------|----------|-----------|
| 0 | Chuẩn bị môi trường | Proxmox, API token, toolbox container trên Dokploy (control node) | [00-setup](docs/00-setup.md) | 1–2 ngày |
| 1 | Terraform cơ bản | provider, resource, state, for_each, templatefile, module | [01-terraform-basics](docs/01-terraform-basics.md) | 2–3 ngày |
| 2 | Ansible cơ bản | inventory, playbook, handler, template, role, idempotency | [02-ansible-basics](docs/02-ansible-basics.md) | 3–4 ngày |
| 3 | Image + VM bằng code | Packer + Ubuntu autoinstall, Terraform `bpg/proxmox`, cloud-init | [03-vm-provisioning](docs/03-vm-provisioning.md) | 3–4 ngày |
| 4 | Bootstrap Kubernetes | kubeadm, containerd, CNI Calico, role Ansible thực tế | [04-bootstrap-kubernetes](docs/04-bootstrap-kubernetes.md) | 4–5 ngày |
| 5 | Add-on bằng Terraform | helm/kubernetes provider, MetalLB, metrics-server, Traefik | [05-addons](docs/05-addons.md) | 2 ngày |
| 6 | Day-2 operations | thêm/bớt node, upgrade, backup/restore etcd, cert | [06-day2-operations](docs/06-day2-operations.md) | 3–4 ngày |
| 7 | Cluster HA *(tuỳ chọn)* | 3 control-plane stacked (chạy cả workload), kube-vip, etcd quorum. Cluster chính vẫn là 1 control-plane + 2 worker | [07-ha-cluster](docs/07-ha-cluster.md) | 2–3 ngày |
| 8 | Golden image | Packer + Ansible bake, immutable upgrade | [08-golden-image](docs/08-golden-image.md) | 2–3 ngày |

\* Ước lượng khi học part-time 1–2 giờ/ngày. Tổng cộng khoảng 5–7 tuần.

**Nguyên tắc học:**

1. **Không bỏ qua giai đoạn 1 và 2.** Đây là phần khái niệm, nếu chưa vững thì sang giai đoạn 3–4 sẽ chỉ copy-paste mà không hiểu.
2. **Gõ lại, đừng copy.** Ví dụ trong docs là để đọc hiểu, còn code trong repo là để đối chiếu.
3. **Mỗi bài tập đều có câu hỏi "tại sao".** Trả lời được thì mới sang bài tiếp.
4. **Phá và dựng lại thường xuyên.** `destroy` rồi `up` lại là cách tốt nhất để chứng minh code của bạn thật sự idempotent và tái tạo được.

## Checklist tiến độ

- [ ] **0** Proxmox chạy, API token hoạt động, toolbox có đủ công cụ
- [ ] **1** Hoàn thành 6 bài Terraform cơ bản, tạo được 1 VM Proxmox bằng Terraform
- [ ] **2** Viết được role nginx idempotent, `ansible-lint` sạch
- [ ] **3** `packer build` ra template, `terraform apply` ra 3 VM, `ansible all -m ping` OK
- [ ] **4** `kubectl get nodes` cả 3 node Ready, chạy `site.yml` lần 2 ra `changed=0`
- [ ] **5** Service LoadBalancer nhận IP MetalLB, `kubectl top nodes` có số liệu
- [ ] **6** Thêm `kubew3`, upgrade 1 minor, backup và restore etcd thành công
- [ ] **7** Tắt `kubec1` mà `kubectl` vẫn hoạt động qua VIP
- [ ] **8** Cluster dựng từ golden image, đo được thời gian nhanh hơn

## Cấu trúc repo (sẽ hình thành dần)

```
devopvips/
├── README.md                     # file này
├── Makefile                      # make up / vms / k8s / addons / destroy
├── .envrc.example                # biến môi trường Proxmox (bản thật không commit)
├── toolbox/                      # container control node: Dockerfile + compose.yml
├── .github/workflows/            # toolbox-image.yml: build + push image toolbox lên GHCR
├── docs/                         # lý thuyết + bài tập từng giai đoạn
├── labs/
│   ├── terraform-basics/         # giai đoạn 1
│   └── ansible-basics/           # giai đoạn 2
├── infra/
│   ├── packer/
│   │   ├── ubuntu-base/          # giai đoạn 3: proxmox-iso + autoinstall
│   │   └── ubuntu-k8s/           # giai đoạn 8: golden image
│   └── terraform/
│       ├── vms/                  # giai đoạn 3: VM + inventory
│       └── addons/               # giai đoạn 5: helm releases
└── ansible/
    ├── ansible.cfg
    ├── inventory/                # hosts.ini do Terraform sinh + group_vars
    ├── roles/                    # common, containerd, kube_packages, control_plane, cni, worker, kube_vip
    └── playbooks/                # site, add-node, remove-node, upgrade, backup-etcd, reset
```

## Quy ước IP và tên

Đổi một lần tại đây, sau đó mọi file `tfvars` và `group_vars` sẽ dùng giá trị này.

| Thành phần | Giá trị mặc định |
|---|---|
| Subnet / Gateway | `10.10.10.0/24` / `10.10.10.254` |
| Proxmox host | `10.10.10.1` (node `homelab`) |
| Template base | VMID `9000` `ubuntu-2404-base` |
| Control-plane | `10.10.10.51–53` (VMID 151–153) |
| API endpoint | `k8s-api.hainth.local`: trỏ `.51` (1 control-plane), sau đó đổi sang `.50` (HA) |
| VIP API (HA) | `10.10.10.50` |
| Worker | `10.10.10.61–69` (VMID 161–169), chỉ có ở giai đoạn 3–6 và 8 |
| MetalLB pool | `10.10.10.80–99` |
| Pod CIDR / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` |
| DNS cho node | `10.10.10.254` (pfSense, có Host Override `k8s-api.hainth.local`) |
| Control node | container `toolbox` trên super-nginx (Dokploy) `10.10.10.201` |
| Đã dùng (không đụng tới) | `.1` Proxmox · `.201` super-nginx (Dokploy) · `.202` jumper · `.254` pfSense |

> Dải IP tĩnh ở trên **phải nằm ngoài dải DHCP** của pfSense LAN (*Services → DHCP Server → LAN*). Kiểm tra trước khi bắt đầu, xem [00-setup, Phần A](docs/00-setup.md#phần-a-kế-hoạch-mạng-trong-pfsense-đừng-bỏ-qua).

## Tài liệu tham khảo chính

- Terraform: https://developer.hashicorp.com/terraform/tutorials
- Provider Proxmox: https://registry.terraform.io/providers/bpg/proxmox/latest/docs
- Packer Proxmox: https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox
- Ansible: https://docs.ansible.com/ansible/latest/getting_started/
- Ubuntu autoinstall: https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html
- kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- Proxmox VE: https://pve.proxmox.com/pve-docs/
