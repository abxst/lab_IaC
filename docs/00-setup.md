# Giai đoạn 0: Chuẩn bị môi trường

Mục tiêu: khi xong giai đoạn này bạn có
1. Mạng lab đã được lên kế hoạch trong pfSense: dải IP tĩnh và tên `k8s-api.hainth.local`.
2. Proxmox `homelab` có **API token** cho Terraform/Packer, kèm quyền SSH bằng key.
3. **Toolbox container** chạy trên host Dokploy (`super-nginx`, `10.10.10.201`) làm control node, có đủ terraform, packer, ansible, ansible-lint, kubectl, helm và SSH key cho lab.
4. Repo đã lên Git remote; toolbox lấy code về bằng `git pull`.
5. ISO Ubuntu Server 24.04 nằm sẵn trên storage của Proxmox.

## Sơ đồ thực tế

```
Laptop chính (nơi viết code) ──git push──► GitHub (private repo)
      │                                         │ git pull
      └──Tailscale──► Jump 10.10.10.202 (RDP, VS Code)
                          │ Remote-SSH + Attach Container
                          ▼
                super-nginx 10.10.10.201 (host Dokploy)
                  └─ container "toolbox" = CONTROL NODE   (~/devopvips)
                       │ Proxmox API / SSH / kubectl
Mạng nhà 192.168.1.0/24 ◄─Wi-Fi─ homelab
                                  │  vmbr1 172.16.100.0/24 ── pfSense WAN
                                  │  vmbr0 10.10.10.0/24   ── pfSense LAN 10.10.10.254 (gateway, DHCP, DNS)
                                  │       ├─ homelab (Proxmox) 10.10.10.1:8006
                                  │       ├─ jumper .202 · super-nginx (Dokploy) .201
                                  │       └─ kubec1 .51 · kubew1 .61 · kubew2 .62 · MetalLB .80–.99
```
Mọi thao tác Terraform, Ansible và kubectl đều chạy **trong toolbox**. Jump dùng để mở VS Code và trình duyệt.

---

## Phần A: Kế hoạch mạng trong pfSense (đừng bỏ qua)

Mở `https://10.10.10.254` từ Jump.

1. **Xem dải DHCP của LAN:** *Services → DHCP Server → LAN*, ghi lại dải *Address Pool* (ví dụ `10.10.10.100–10.10.10.199`).
2. **Xem các IP đang được dùng:**
   - *Status → DHCP Leases*;
   - *Diagnostics → ARP Table*. Hiện đã biết: `.1` proxmox, `.201` super-nginx (Dokploy), `.202` jumper, `.254` pfsense.
3. Các IP tĩnh của lab (xem bảng trong README) phải **nằm ngoài dải DHCP** và không trùng với máy nào. Nếu trùng, hãy chọn dải khác và sửa ở README.

   Kiểm tra bằng PowerShell trên Jump:
   ```powershell
   50,51,52,53,59,61,62,63,80,99 | ForEach-Object { "10.10.10.$_ : " + (Test-Connection "10.10.10.$_" -Count 1 -Quiet) }
   ```
   Tất cả phải ra `False`.
4. **Khai báo tên cho API của K8s:** *Services → DNS Resolver → Host Overrides → Add*

   Thêm vào cạnh các bản ghi `jumper`, `pfsense`, `proxmox`, `super-nginx` đã có:

   | Host | Domain | IP |
   |---|---|---|
   | `k8s-api` | `hainth.local` | `10.10.10.51` (giai đoạn 7 đổi thành VIP `.50`) |
   | `kubec1` | `hainth.local` | `10.10.10.51` |
   | `kubew1` | `hainth.local` | `10.10.10.61` |
   | `kubew2` | `hainth.local` | `10.10.10.62` |
   | `tf-sandbox` | `hainth.local` | `10.10.10.59` (VM của bài 7 giai đoạn 1, tuỳ chọn) |

   > **Lưu ý về đuôi `.local`:** đuôi này vốn dành cho mDNS (RFC 6762). Windows vẫn hỏi pfSense nên không gặp vấn đề, nhưng `systemd-resolved` trên Ubuntu có thể không gửi tên `.local` tới DNS server thường. Ở giai đoạn 3, ta khai báo `hainth.local` làm **search domain** trong cloud-init để node hỏi pfSense đúng cách. Nếu sau này vẫn lỗi phân giải, một lựa chọn bền hơn là chuyển sang domain như `home.arpa` (RFC 8375).

   Kiểm tra từ Jump: `Resolve-DnsName k8s-api.hainth.local` phải ra `10.10.10.51`.

> Nhờ Host Override, mọi máy dùng DNS của pfSense (các node K8s, Jump, host Dokploy và toolbox) đều phân giải được `k8s-api.hainth.local`. Bạn không cần sửa `/etc/hosts` trên từng máy. Muốn chuyển cluster sang HA chỉ cần sửa đúng một chỗ này.

---

## Phần B: Proxmox `homelab` (đã cài, chỉ kiểm tra)

Proxmox VE 9.2 đã chạy, node tên `homelab`, giao diện web ở `https://10.10.10.1:8006`. Các bước dưới đây dùng **Shell** trên giao diện web (hoặc `ssh root@10.10.10.1`).

### B1. Repo
Trên giao diện có dòng *"Non production-ready repository enabled"*: đây là cảnh báo bình thường khi dùng repo `pve-no-subscription`. Kiểm tra lại:
```bash
apt update    # không được có lỗi 401 từ enterprise.proxmox.com
```
Nếu còn lỗi 401: thêm dòng `Enabled: no` vào cuối `/etc/apt/sources.list.d/pve-enterprise.sources` và `ceph.sources`.

### B2. Gập máy không sleep
```bash
grep HandleLidSwitch /etc/systemd/logind.conf    # cần cả 3 dòng = ignore, không có dấu #
```
Nếu chưa đúng:
```bash
sed -i -E 's/^#?HandleLidSwitch=.*/HandleLidSwitch=ignore/; s/^#?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/; s/^#?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind
```

### B3. Wi-Fi uplink
Proxmox ra Internet qua Wi-Fi (`wlp0s20f3`). Tắt chế độ tiết kiệm điện của card Wi-Fi để tránh rớt mạng ngẫu nhiên. Việc này ảnh hưởng tới lúc tải image hoặc package:
```bash
iw dev wlp0s20f3 get power_save
iw dev wlp0s20f3 set power_save off
```
Muốn giữ cấu hình sau reboot, thêm `post-up iw dev wlp0s20f3 set power_save off` vào block `iface wlp0s20f3` trong `/etc/network/interfaces`.

### B4. Storage
```bash
pvesm status
pvesm set local --content iso,vztmpl,backup,snippets,import
```
- `local` (thư mục `/var/lib/vz`): ISO, snippets, backup, file import.
- `local-lvm` (LVM-thin, còn trống khoảng 320GB): disk của VM và template.

### B5. Tải ISO Ubuntu Server 24.04 lên Proxmox
Vào https://releases.ubuntu.com/24.04/ để xem tên file mới nhất (dạng `ubuntu-24.04.X-live-server-amd64.iso`), rồi:
```bash
cd /var/lib/vz/template/iso
wget https://releases.ubuntu.com/24.04/ubuntu-24.04.X-live-server-amd64.iso   # thay X
wget -qO- https://releases.ubuntu.com/24.04/SHA256SUMS | grep live-server | sha256sum -c --ignore-missing
```
Hoặc trên giao diện web: **local → ISO Images → Download from URL**.

### B6. User + role + API token cho Terraform/Packer
Theo nguyên tắc **least privilege**: tạo một role riêng chỉ có các quyền cần thiết, không dùng `root@pam`.

```bash
pveum role add TerraformProv -privs "\
Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Pool.Audit Sys.Audit Sys.Console Sys.Modify SDN.Use \
VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU \
VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.Migrate VM.PowerMgmt VM.GuestAgent.Audit"

pveum user add terraform@pve --comment "Terraform + Packer automation"
pveum aclmod / -user terraform@pve -role TerraformProv
pveum user token add terraform@pve automation --privsep 0
```

Lệnh cuối in ra **secret, chỉ hiện một lần**. Lưu ngay vào password manager.
- Token ID: `terraform@pve!automation`
- Secret: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

> - Nếu `pveum role add` báo một privilege không tồn tại (tên privilege thay đổi giữa các bản PVE), hãy bỏ privilege đó đi rồi chạy lại.
> - `--privsep 0`: token dùng chung quyền với user.
> - Khi provider báo lỗi `403 Permission check failed (..., <privilege>)`, cách sửa đúng là thêm đúng privilege bị thiếu vào role: `pveum role modify TerraformProv -append 1 -privs "<privilege>"`. **Đừng** chuyển sang dùng root.
> - Role này cho phép quản lý **mọi** VM, kể cả pfSense, Jump và Dokploy. Muốn an toàn hơn: tạo pool `k8s` (`pveum pool add k8s`), chỉ cấp quyền VM trên `/pool/k8s` và quyền storage trên `/storage/...`, rồi cho Terraform tạo VM vào pool đó. Đây là bài tập tốt sau khi đã chạy được bản đơn giản.

### B7. SSH bằng key vào Proxmox
Một số thao tác của provider `bpg/proxmox`, như upload snippet hay import disk, cần SSH vào node. Sau khi tạo key ở bước C4, chạy **trong toolbox**:
```bash
ssh-copy-id -i ~/.ssh/k8s_lab.pub root@10.10.10.1
ssh -i ~/.ssh/k8s_lab root@10.10.10.1 pveversion
```

---

## Phần C: Toolbox container trên Dokploy (control node)

Toolbox là một container Ubuntu 24.04, định nghĩa trong [toolbox/](../toolbox/):
- [Dockerfile](../toolbox/Dockerfile): pin version mọi công cụ, kiểm tra checksum khi tải.
- [compose.yml](../toolbox/compose.yml): chạy container.

```
host super-nginx
└─ /opt/devops-toolbox/home  ──bind mount──►  /home/devops (trong container)
     ├─ devopvips/      repo (git clone) + terraform.tfstate
     ├─ .ssh/  .kube/   key, kubeconfig
     └─ .terraform.d/   cache provider
```

> **Vì sao chạy bằng `docker compose` riêng, không deploy qua Dokploy?** Dokploy được thiết kế để build, redeploy và healthcheck ứng dụng, nên có thể tự dựng lại container. Toolbox là môi trường làm việc có state, nên ta tự quản lý nó.
>
> **Vì sao `network_mode: host`?** Container dùng thẳng mạng của host: thấy `10.10.10.0/24`, DNS đi qua pfSense nên phân giải được `*.hainth.local`, không phải lo NAT. Packer đưa autoinstall vào VM bằng ổ CD, nên không có kết nối nào phải đi ngược vào container.

### C1. Đưa repo lên Git remote (trên laptop chính)
Tạo một **private repo** trên GitHub (hoặc GitLab/Gitea), rồi push từ `d:\code\devopvips`:
```bash
git init
git add -A && git commit -m "Initial lab docs and Terraform basics"
git branch -M main
git remote add origin https://github.com/<you>/devopvips.git
git push -u origin main
```
`.gitignore` đã chặn `*.tfstate`, `*.tfvars`, `.envrc`, `.env`, kubeconfig và key. Dù vậy, trước lần push đầu tiên hãy chạy `git status` để chắc chắn không có file bí mật nào.

**Quyền đọc repo từ host Dokploy và toolbox** (chọn một):
- **Deploy key, khuyến nghị:** tạo một key riêng, add vào repo với quyền *read-only* (*Settings → Deploy keys*). Toolbox chỉ cần kéo code về, không cần push.
- **HTTPS + Personal Access Token** (fine-grained, chỉ quyền *Contents: Read* trên đúng repo này).

### C2. Chuẩn bị host Dokploy, clone, build toolbox
SSH vào `super-nginx` (từ Jump: `ssh <user>@super-nginx.hainth.local`):
```bash
id                                  # ghi lại uid/gid, và xem user đã thuộc nhóm docker chưa
docker version && docker compose version
sudo mkdir -p /opt/devops-toolbox/home
```
Nếu `docker version` báo `permission denied ... docker.sock`, user chưa thuộc nhóm `docker`. VS Code cũng cần quyền này để attach vào container:
```bash
sudo usermod -aG docker $USER
exit        # đăng xuất rồi SSH vào lại, kiểm tra: id | grep docker
```
> Nhóm `docker` gần như tương đương quyền root trên host. Chấp nhận được với user vốn đã có sudo.
Chọn UID cho user `devops` trong container:
- Nếu user trên host **không phải root**: dùng đúng `id -u` / `id -g` của user đó, để file trong thư mục home sửa được từ cả host lẫn container.
- Nếu bạn SSH bằng **root**: dùng `1000:1000`.

```bash
TB_UID=1000; TB_GID=1000            # hoặc $(id -u) / $(id -g), xem ở trên
sudo chown -R $TB_UID:$TB_GID /opt/devops-toolbox/home

# Clone repo vào đúng thư mục sẽ trở thành ~/devopvips trong toolbox
# (user có uid = TB_UID thì clone thẳng; nếu không thì thêm: sudo -u "#$TB_UID")
git clone https://github.com/abxst/lab_IaC.git /opt/devops-toolbox/home/devopvips

cd /opt/devops-toolbox/home/devopvips/toolbox
cp .env.example .env               # uid khác 1000 thì sửa TOOLBOX_UID / TOOLBOX_GID
docker compose pull                # tải image do GitHub Actions build sẵn
docker compose up -d
docker exec -it toolbox bash       # prompt hiện "(toolbox) devops:~$"
```

**Image do GitHub Actions build.** Workflow [.github/workflows/toolbox-image.yml](../.github/workflows/toolbox-image.yml):
- chạy mỗi khi push lên `main` có thay đổi trong `toolbox/`;
- build image, chạy smoke test (gọi version của mọi công cụ);
- đẩy lên `ghcr.io/abxst/lab_iac/toolbox` với 2 tag: `latest` và `sha-xxxxxxx`.

Lần đầu tiên, vào tab **Actions** của repo, chọn *toolbox-image → Run workflow* để có image đầu tiên.

> **Image trên GHCR của repo private mặc định cũng là private.** Có 2 cách để host pull được:
> - **Đăng nhập GHCR trên host** (khuyến nghị): tạo PAT (classic) chỉ có quyền `read:packages`, rồi:
>   ```bash
>   echo '<PAT>' | docker login ghcr.io -u abxst --password-stdin
>   ```
> - **Đặt package thành public** (*GitHub → Your profile → Packages → toolbox → Package settings → Change visibility*). Image không chứa bí mật nào, nhưng sẽ lộ danh sách công cụ và version bạn dùng.
>
> Image được build với UID/GID `1000:1000`. Nếu user trên host có uid khác, hãy build tại chỗ bằng `docker compose up -d --build`, compose sẽ dùng UID trong `.env`.
Trong toolbox, kiểm tra:
```bash
terraform version; packer version; ansible --version | head -1; ansible-lint --version
kubectl version --client; helm version --short
ping -c2 10.10.10.1
getent hosts k8s-api.hainth.local     # 10.10.10.51
```

### C3. Làm việc hằng ngày

**Mở toolbox bằng VS Code trên Jump:**
1. Cài 2 extension: **Remote - SSH** và **Dev Containers**.
2. *Remote-SSH: Connect to Host* → `<user>@super-nginx.hainth.local`.
3. Trong cửa sổ đó: *Dev Containers: Attach to Running Container…* → chọn `toolbox`.
4. *File → Open Folder* → `/home/devops/devopvips`.

Từ đây, terminal trong VS Code chạy ngay trong toolbox. VS Code server được cài vào `~/.vscode-server`, nằm trên volume nên không bị mất khi build lại image.

> Bước 3 cần user SSH vào host có quyền chạy `docker` (thuộc nhóm `docker`, hoặc là root).
>
> Cách không dùng VS Code: `ssh super-nginx.hainth.local` rồi `docker exec -it toolbox bash`.

**Lấy code mới** (sau khi bạn push từ laptop chính), trong toolbox:
```bash
cd ~/devopvips && git pull
```
`git pull` an toàn với state: `terraform.tfstate`, `.terraform/`, `.envrc`, `hosts.ini` đều nằm trong `.gitignore`, nên Git không đụng tới chúng.

> - Chỉ sửa code ở **một phía**, tức là laptop chính. Nếu lỡ sửa trong toolbox, hãy `git stash` trước khi `pull`.
> - **Không bao giờ** `git clean -fdx` trong `~/devopvips`: lệnh này xoá luôn các file bị ignore, tức là xoá state Terraform.
> - Nếu `toolbox/` thay đổi: đợi workflow trên GitHub chạy xong (tab Actions), rồi trên **host** chạy `cd /opt/devops-toolbox/home/devopvips/toolbox && docker compose pull && docker compose up -d`. Container được tạo lại với image mới, còn dữ liệu trong `/home/devops` giữ nguyên.

### C4. SSH key cho lab
Trong toolbox:
```bash
ssh-keygen -t ed25519 -C "k8s-lab" -f ~/.ssh/k8s_lab -N ""
cat ~/.ssh/k8s_lab.pub      # key này sẽ được nhúng vào template và cloud-init
```
Dùng key riêng cho lab: nếu bị lộ thì chỉ cần thay key này, không ảnh hưởng key cá nhân.

Thêm vào `~/.ssh/config` để Ansible và SSH tự dùng key này cho các node K8s:
```
Host kubec* kubew* tf-sandbox* 10.10.10.5? 10.10.10.6?
    User ansible
    IdentityFile ~/.ssh/k8s_lab
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts_lab
```
```bash
chmod 600 ~/.ssh/config
```
> - Pattern `10.10.10.5?` và `10.10.10.6?` chỉ khớp với `.50–.59` và `.60–.69`, tức là các node K8s. Nhờ vậy cấu hình này không ảnh hưởng khi SSH vào Proxmox (`.1`), pfSense hay Dokploy.
> - `UserKnownHostsFile` riêng giúp dễ dọn dẹp: VM sẽ bị xoá và tạo lại nhiều lần với cùng IP nhưng host key mới. Khi đó chỉ cần `rm ~/.ssh/known_hosts_lab`.

Sau đó làm bước B7 (đưa key vào Proxmox).

### C5. Biến môi trường Proxmox
```bash
cd ~/devopvips
cp .envrc.example .envrc     # điền token ở bước B6; .envrc nằm trong .gitignore, KHÔNG commit
direnv allow
```
Nội dung chính của `.envrc`:
```bash
export PROXMOX_VE_ENDPOINT="https://10.10.10.1:8006/"
export PROXMOX_VE_API_TOKEN='terraform@pve!automation=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
export PROXMOX_VE_INSECURE=true          # lab dùng cert tự ký
# ... cùng các biến SSH, Packer, KUBECONFIG, xem .envrc.example
```
> Dùng **nháy đơn** cho token vì chuỗi có ký tự `!`. Trong bash, `!` nằm trong nháy kép sẽ bị hiểu là history expansion.

### C6. Nâng cấp và backup toolbox
- **Nâng version một công cụ:** sửa `ARG` trong Dockerfile trên laptop chính → push → GitHub Actions build và push image mới → trên host chạy `docker compose pull && docker compose up -d`. Dữ liệu trong `/home/devops` vẫn còn nguyên.
- **Quay lại bản cũ khi bản mới lỗi:** đặt `TOOLBOX_IMAGE=ghcr.io/abxst/lab_iac/toolbox:sha-<commit cũ>` trong `.env`, rồi `docker compose up -d`.
- **Lấy bản vá bảo mật của Ubuntu:** chạy workflow bằng tay (*Run workflow*) khoảng mỗi tháng một lần.
- **Backup:** chỉ cần backup thư mục `/opt/devops-toolbox/home` trên host, vì trong đó có state Terraform. Ví dụ: `sudo tar czf ~/toolbox-home-$(date +%F).tgz -C /opt/devops-toolbox home`.
- ⚠️ **Không** chạy `docker compose down -v`, và không xoá thư mục đó.

---

## Phần D: Kiểm tra cuối giai đoạn

Chạy từng lệnh **trong toolbox**. Tất cả phải chạy được thì mới sang giai đoạn 1.

```bash
cd ~/devopvips   # direnv nạp .envrc

# API token hoạt động: phải trả về JSON có "version"
curl -sk -H "Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}" \
  "${PROXMOX_VE_ENDPOINT}api2/json/version" | jq

# Token thấy được node và storage
curl -sk -H "Authorization: PVEAPIToken=${PROXMOX_VE_API_TOKEN}" \
  "${PROXMOX_VE_ENDPOINT}api2/json/nodes/homelab/storage" | jq -r '.data[].storage'

# SSH bằng key vào Proxmox
ssh -i ~/.ssh/k8s_lab root@10.10.10.1 'pveversion && ls /var/lib/vz/template/iso'

# DNS lab
getent hosts k8s-api.hainth.local
```

### Checklist
- [ ] Đã ghi lại dải DHCP của pfSense LAN, và các IP .50–.69, .80–.99 đều còn trống
- [x] pfSense có Host Override `k8s-api`, `kubec1`, `kubew1`, `kubew2` (domain `hainth.local`)
- [ ] Repo đã lên Git remote (private), host Dokploy clone được
- [ ] Toolbox chạy (`docker ps` thấy `toolbox`), có đủ 6 công cụ
- [ ] VS Code trên Jump attach được vào toolbox, mở được `/home/devops/devopvips`
- [ ] `curl` API bằng token trả về version
- [ ] ISO Ubuntu 24.04 live-server có trong `local`
- [ ] Có key `~/.ssh/k8s_lab` trong toolbox, và đăng nhập root Proxmox bằng key được

## Lỗi thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| `Permission denied` khi ghi vào `/home/devops` | Thư mục `/opt/devops-toolbox/home` trên host chưa thuộc UID trong `.env`. Chạy lại `chown` ở bước C2 |
| `docker compose pull` báo `denied` hoặc `unauthorized` | Package trên GHCR là private mà host chưa `docker login ghcr.io` (xem bước C2), hoặc workflow chưa chạy lần nào nên chưa có image |
| Workflow `toolbox-image` báo đỏ | Mở log trên tab Actions. Lỗi ở bước build: thường do mạng hoặc sai checksum, kiểm tra version trong `ARG`. Lỗi ở bước Smoke test: một công cụ không chạy được |
| `git clone`/`git pull` hỏi mật khẩu hoặc báo `403` | Repo private. Dùng deploy key hoặc PAT (bước C1). Với HTTPS, PAT nhập vào chỗ password |
| Toolbox không phân giải được `*.hainth.local` | DNS của host Dokploy không trỏ về `10.10.10.254`. Kiểm tra `resolvectl status` trên host |
| VS Code không thấy container khi Attach | User SSH vào host chưa có quyền docker: `sudo usermod -aG docker <user>`, rồi đăng xuất và vào lại |
| `401 Unauthorized` khi gọi API | Sai định dạng token. Header phải là `PVEAPIToken=terraform@pve!automation=<secret>` |
| `403 Permission check failed` | Role thiếu privilege. Thêm bằng `pveum role modify ... -append 1` |
| Tải ISO hoặc package trên Proxmox chậm, hay đứt | Wi-Fi uplink. Tắt power save (B3), hoặc tải ISO về Jump rồi upload qua giao diện web |
| Mất state Terraform | Đã chạy `git clean -fdx` hoặc `docker compose down -v`, hoặc làm việc ngoài `~/devopvips`. Khôi phục từ bản backup (C6) |

➡️ Tiếp theo: [01: Terraform cơ bản](01-terraform-basics.md)
