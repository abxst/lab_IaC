# Giai đoạn 6: Day-2 operations

"Day-1" là dựng cluster. "Day-2" là mọi thứ diễn ra sau đó và kéo dài suốt vòng đời cluster: thêm/bớt node, nâng version, backup, xoay vòng cert, xử lý sự cố. Đây là phần tạo ra giá trị thật của tự động hoá.

Code sẽ nằm ở `ansible/playbooks/`.

| Playbook | Việc |
|---|---|
| `add-node.yml` | Thêm node vào cluster |
| `remove-node.yml` | Đưa node ra khỏi cluster an toàn |
| `upgrade.yml` | Nâng K8s lên 1 minor |
| `backup-etcd.yml` | Snapshot etcd + PKI, kéo về toolbox |
| `restore-etcd.yml` | Khôi phục etcd từ snapshot |
| `reset.yml` | `kubeadm reset` toàn bộ để làm lại |

---

## 1. Thêm node
Quy trình: Terraform tạo VM trước, Ansible cấu hình sau, và **chỉ chạy trên node mới**.
```bash
# 1. thêm "kubew3" vào nodes trong terraform.tfvars
cd infra/terraform/vms && terraform apply          # 1 to add, hosts.ini tự cập nhật
# 2. chỉ cấu hình node mới, nhưng vẫn cần control plane để lấy lệnh join
cd ../../../ansible
ansible-playbook playbooks/site.yml --limit 'kubew3,control_plane'
```
❓ Vì sao `--limit` phải có cả `control_plane`? (Gợi ý: task `delegate_to` lấy join command.)

## 2. Bớt node
Thứ tự đúng: **K8s trước, hạ tầng sau**. Làm ngược lại thì pod chết đột ngột, không được dời sang node khác.
```yaml
# remove-node.yml (rút gọn), chạy với -e node=kubew3
- hosts: localhost
  tasks:
    - name: Drain
      kubernetes.core.k8s_drain:
        name: "{{ node }}"
        delete_options:
          ignore_daemonsets: true
          delete_emptydir_data: true
          terminate_grace_period: 60
    - name: Xoá node khỏi cluster
      kubernetes.core.k8s:
        kind: Node
        name: "{{ node }}"
        state: absent

- hosts: "{{ node }}"
  become: true
  tasks:
    - name: Reset kubeadm trên node
      ansible.builtin.command: kubeadm reset -f
```
Sau đó xoá node khỏi `nodes` trong tfvars, rồi `terraform apply` (1 to destroy).

## 3. Nâng version Kubernetes
Quy tắc:
- Chỉ nâng **từng minor một** (lab: 1.36 lên 1.37). Không được nhảy cóc.
- Thứ tự: **control-plane trước, worker sau**. kubelet được phép cũ hơn API server, nhưng không được mới hơn.
- Mỗi lần chỉ nâng 1 node (`serial: 1`). Node nào lỗi thì dừng ngay (`max_fail_percentage: 0`).
- Trước khi nâng: **backup etcd** (mục 4), **snapshot các VM trên Proxmox**, và đọc changelog của minor mới (API nào bị bỏ).

```
Mọi node:          đổi repo pkgs.k8s.io sang minor mới
CP đầu tiên:       unhold → cài kubeadm mới → kubeadm upgrade plan → kubeadm upgrade apply vX.Y.Z
                   → drain → nâng kubelet + kubectl → restart kubelet → uncordon
CP còn lại (HA):   cài kubeadm mới → kubeadm upgrade node → drain → kubelet → uncordon
Từng worker:       cài kubeadm mới → kubeadm upgrade node → drain → kubelet → uncordon
Sau cùng:          hold lại gói · nâng KUBECTL_VERSION trong toolbox/Dockerfile · kiểm tra Calico và các add-on còn tương thích
```

Khung play cho worker:
```yaml
- name: Nâng worker
  hosts: workers
  become: true
  serial: 1
  max_fail_percentage: 0
  pre_tasks:
    - name: Drain
      kubernetes.core.k8s_drain:
        name: "{{ inventory_hostname }}"
        delete_options:
          ignore_daemonsets: true
          delete_emptydir_data: true
      delegate_to: localhost
      become: false
  roles:
    - role: kube_upgrade          # repo, kubeadm, kubeadm upgrade node, kubelet, restart
  post_tasks:
    - name: Uncordon
      kubernetes.core.k8s_drain:
        name: "{{ inventory_hostname }}"
        state: uncordon
      delegate_to: localhost
      become: false
```
Kiểm tra: `kubectl get nodes` phải hiện version mới trên mọi node, và `kubeadm upgrade plan` báo đã ở bản mới nhất.

> **PodDisruptionBudget:** `drain` tôn trọng PDB. Nếu một app chỉ có 1 replica mà PDB lại đặt `minAvailable: 1`, drain sẽ treo mãi. Bài tập 2 sẽ cho bạn gặp tình huống này.

## 4. Backup etcd
etcd chứa **toàn bộ trạng thái** của cluster. Mất etcd mà không có backup thì mất cluster.

Image etcd của kubeadm có sẵn `etcdctl`. Thư mục `/var/lib/etcd` là hostPath, nên file snapshot sẽ nằm trên node:
```bash
kubectl -n kube-system exec etcd-kubec1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db
```
Playbook `backup-etcd.yml` sẽ:
1. chạy lệnh trên với tên file có timestamp;
2. `fetch` file snapshot **và thư mục `/etc/kubernetes/pki/`** về `backups/<ngày>/` trong toolbox (nằm trên volume nên được backup cùng thư mục home). Không có CA cũ thì snapshot gần như vô dụng khi phải dựng lại control plane;
3. xoá các snapshot cũ trên node, chỉ giữ N bản gần nhất.

Thư mục `backups/` đã nằm trong `.gitignore`, vì nó chứa private key của CA.

### Restore (cluster 1 control-plane)
```
1. Dừng control plane: chuyển các file trong /etc/kubernetes/manifests ra chỗ khác
2. etcdutl snapshot restore snapshot.db --data-dir /var/lib/etcd-restored
   (tải etcdutl đúng với version etcd đang chạy)
3. Thay /var/lib/etcd bằng /var/lib/etcd-restored
4. Trả các manifest về chỗ cũ → kubelet tự dựng lại control plane
5. Restart kubelet trên mọi node
```
Đừng coi là đã có backup cho tới khi đã **restore thử thành công** ít nhất một lần.

## 5. Cert
```bash
sudo kubeadm certs check-expiration   # cert thường có hạn 1 năm, CA có hạn 10 năm
sudo kubeadm certs renew all          # renew thủ công, sau đó phải restart các static pod
```
- `kubeadm upgrade apply` **tự động renew** cert. Cluster được nâng version đều đặn sẽ không gặp chuyện cert hết hạn.
- Client cert của kubelet tự xoay vòng. Serving cert do kubelet-csr-approver lo (giai đoạn 5).
- Sau khi renew, file `admin.conf` có cert mới, nên phải `fetch` lại về toolbox.

## 6. Snapshot VM trên Proxmox: lưới an toàn của lab
```bash
# trên Proxmox
for id in 151 161 162; do qm snapshot $id pre-upgrade --description "before 1.xx"; done
qm rollback 151 pre-upgrade          # quay lại khi upgrade hỏng
qm delsnapshot 151 pre-upgrade       # dọn snapshot khi đã ổn
```
Bài tập nhỏ: viết thành playbook `proxmox-snapshot.yml`, chạy trên host Proxmox bằng module `community.general.proxmox_snap`, hoặc `command: qm snapshot`.

> Snapshot VM **không thay thế** backup etcd. Rollback từng VM ở các thời điểm khác nhau sẽ làm etcd mất nhất quán. Chỉ dùng snapshot cho lab, và chỉ rollback **tất cả VM về cùng một snapshot**.

---

## 7. Bài tập
1. Thêm `kubew3`, deploy 6 replica nginx, rồi `remove-node.yml` node đó. Đếm xem có request nào bị lỗi không (chạy `curl` liên tục qua Service LoadBalancer).
2. Tạo PDB `minAvailable: 1` cho một deployment chỉ có 1 replica, rồi drain node đang chạy pod đó. Quan sát drain bị treo, sau đó xử lý.
3. Nâng cluster lên 1 minor bằng `upgrade.yml`. Vừa nâng vừa chạy `curl` liên tục để kiểm chứng app không bị gián đoạn.
4. **Diễn tập thảm hoạ:** backup etcd → `kubectl delete ns demo` → restore → namespace `demo` quay lại.
5. Chạy `backup-etcd.yml` định kỳ bằng cron trên host Dokploy gọi `docker exec toolbox ...`, giữ 7 bản gần nhất.
6. `sudo kubeadm certs check-expiration` trước và sau khi upgrade. Cert nào đã được làm mới?

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| `kubeadm upgrade apply` báo `version skew` | Nhảy cóc minor, hoặc kubelet trên một node đang mới hơn API server |
| `apt` không thấy version mới | Repo `pkgs.k8s.io` vẫn trỏ minor cũ |
| Drain treo | Do PDB, hoặc có pod không thuộc controller nào (cần `--force`) |
| Sau restore, node `NotReady` | Chưa restart kubelet, hoặc snapshot cũ hơn lần join của node |

➡️ Tiếp theo: [07: Cluster HA](07-ha-cluster.md)
