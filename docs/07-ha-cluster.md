# Giai đoạn 7 (nâng cao): HA với 3 control-plane "stacked"

Mục tiêu: cluster có **3 node, node nào cũng vừa là control-plane vừa chạy workload**. API server truy cập qua **VIP `10.10.10.50`**. Tắt 1 node bất kỳ thì cluster vẫn chạy.

```
                  k8s-api.hainth.local → 10.10.10.50 (VIP, kube-vip ARP)
                         │  VIP nằm trên node đang là leader
        ┌────────────────┼────────────────┐
   kubec1 .51      kubec2 .52      kubec3 .53       mỗi node 2 vCPU / 3 GB
   apiserver        apiserver        apiserver
   etcd ◄──────────► etcd ◄─────────► etcd             (quorum 2/3)
   + workload       + workload       + workload        (đã gỡ taint control-plane)
```

**Vì sao chọn mô hình này cho lab?** Host Proxmox đang chạy sẵn pfSense, Jump và Dokploy (khoảng 16GB), chỉ còn khoảng 13GB trống. Mô hình 3 control-plane + 2 worker cần khoảng 15GB, không vừa. Mô hình 3 node stacked chỉ cần **9GB**, bằng đúng cụm 1 control-plane + 2 worker ở giai đoạn 4. Đây cũng là mô hình HA phổ biến cho cluster nhỏ và edge (k3s, Talos, MicroK8s thường chạy kiểu này).

---

## 1. Lý thuyết cần nắm

### etcd và quorum
etcd dùng thuật toán Raft: muốn ghi dữ liệu thì cần **đa số** thành viên đồng ý.

| Số thành viên | Quorum | Chịu được bao nhiêu node hỏng |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0**, không hơn gì 1 node mà lại thêm một điểm có thể hỏng |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

→ Luôn dùng số lẻ thành viên. Có 2 member chỉ được phép là **trạng thái chuyển tiếp** trong vài phút lúc join node.

### Vì sao cần VIP?
Kubelet, kube-proxy, kubectl và mọi kubeconfig đều trỏ tới **một địa chỉ** (`controlPlaneEndpoint`). Nếu địa chỉ đó là IP của kubec1, thì kubec1 chết là cả cluster mất liên lạc.
**kube-vip** chạy dạng static pod trên mỗi control-plane. Các instance bầu ra một leader, và leader trả lời ARP cho VIP. Khi leader chết, node khác nhận VIP chỉ trong vài giây.

> Trong production thường đặt LB (HAProxy + keepalived, hoặc LB phần cứng) ở bên ngoài. kube-vip phù hợp cho homelab và edge vì không cần thêm máy.

### Vì sao dùng tên DNS làm endpoint?
Ở giai đoạn 4 ta đã đặt `controlPlaneEndpoint: k8s-api.hainth.local`, trỏ tới `.51`. Lên HA chỉ cần **đổi bản ghi** sang `.50`, không phải cấp lại cert hay kubeconfig.

### Cái giá của mô hình stacked
Workload chạy chung máy với apiserver và etcd, nên một app ngốn RAM có thể làm chết control-plane. Cần thêm 3 lớp bảo vệ:

1. **Giữ tài nguyên cho hệ thống** trong `KubeletConfiguration`:
   ```yaml
   systemReserved:
     memory: 512Mi
     cpu: 250m
   kubeReserved:
     memory: 512Mi
     cpu: 250m
   evictionHard:
     memory.available: 200Mi
   ```
   Với RAM 3GB, workload còn khoảng 1.7GB mỗi node.
2. **Mọi workload đều phải có `requests`/`limits`.** Có thể ép điều này bằng `LimitRange` mặc định cho từng namespace.
3. **Dự phòng N-1:** khi drain 1 node để upgrade, 2 node còn lại phải chứa được toàn bộ workload. Tổng `requests` của app nên dưới khoảng 3.4GB (2 × 1.7GB).

---

## 2. Gỡ taint và label của control-plane

kubeadm gắn sẵn cho mỗi control-plane:

| Gắn sẵn | Tác dụng | Với mô hình stacked |
|---|---|---|
| Taint `node-role.kubernetes.io/control-plane:NoSchedule` | Pod thường không được xếp lên node | **Gỡ**, để node chạy được workload |
| Label `node.kubernetes.io/exclude-from-external-load-balancers` | MetalLB **không quảng bá IP LoadBalancer** từ node này | **Gỡ**, nếu không Service LoadBalancer sẽ có IP nhưng không ai trả lời ARP |

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl label nodes --all node.kubernetes.io/exclude-from-external-load-balancers-
```
Trong code, role `control_plane` sẽ làm việc này khi biến `control_plane_schedulable: true`, để node nào join sau cũng tự được xử lý.

---

## 3. Hai con đường (nên làm cả hai)

### Đường A: dựng mới từ đầu (dễ hơn, làm trước)
1. Sửa tfvars: chỉ có `kubec1/2/3` (`.51/.52/.53`), không có worker. `make destroy && make vms`.
2. `group_vars`:
   ```yaml
   ha_enabled: true
   control_plane_schedulable: true
   vip_address: 10.10.10.50
   ```
   Sửa Host Override `k8s-api.hainth.local` trên pfSense sang `.50`.
3. Role `kube_vip` sinh manifest **trước khi** chạy `kubeadm init`:
   ```bash
   ctr image pull ghcr.io/kube-vip/kube-vip:vX.Y.Z
   ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:vX.Y.Z vip /kube-vip manifest pod \
     --interface ens18 --address 10.10.10.50 \
     --controlplane --arp --leaderElection > /etc/kubernetes/manifests/kube-vip.yaml
   ```
   NIC virtio trên Proxmox thường tên là `ens18`. Kiểm tra bằng `ip -br link`.
4. **Bẫy `super-admin.conf`** (từ K8s 1.29 trở đi): trong lúc `kubeadm init`, file `admin.conf` **chưa có quyền** (RBAC được tạo sau), nên kube-vip trên **node đầu tiên** không lấy được lease, VIP không lên, và `init` bị treo. Cách xử lý:
   - chỉ trên kubec1, trước khi init: sửa manifest để mount `/etc/kubernetes/super-admin.conf`;
   - init xong: đổi lại về `admin.conf`.

   Role phải tự động làm cả 2 bước này.
5. kubec1: `kubeadm init --config ... --upload-certs` (cert CA, etcd và SA được mã hoá và đẩy lên Secret, có hiệu lực **2 giờ**).
6. kubec2 rồi kubec3 (**lần lượt từng node**): sinh manifest kube-vip, sau đó:
   ```bash
   kubeadm join k8s-api.hainth.local:6443 --token ... --discovery-token-ca-cert-hash sha256:... \
     --control-plane --certificate-key <key>
   ```
   Lấy lệnh này bằng `delegate_to` kubec1:
   ```bash
   kubeadm init phase upload-certs --upload-certs        # in ra certificate-key mới
   kubeadm token create --print-join-command --certificate-key <key>
   ```
7. Gỡ taint và label (mục 2), cài CNI, rồi chạy lại Terraform add-on (giai đoạn 5).

### Đường B: chuyển tại chỗ từ 1 control-plane + 2 worker (gần với thực tế hơn)
Ràng buộc: **RAM của host không cho phép chạy cùng lúc 5 VM.** Vì vậy phải đưa worker ra trước, rồi mới thêm control-plane.

```
Hiện tại:  kubec1 + w1 + w2               (9GB)
Bước 3:    kubec1 (gánh hết workload)     (3GB)   ← giai đoạn yếu nhất, làm nhanh
Bước 6:    kubec1 + kubec2 + kubec3             (9GB)
```
1. Backup etcd và PKI, snapshot VM (giai đoạn 6).
2. Gỡ taint và label trên kubec1 (mục 2) để kubec1 nhận được workload.
3. `remove-node.yml` lần lượt `kubew1`, `kubew2`: pod dời hết sang kubec1. Nếu kubec1 thiếu RAM, hãy tạm scale down các app không quan trọng.
4. Cài kube-vip trên kubec1. Cluster đã có sẵn nên dùng `admin.conf`, **không cần** `super-admin.conf`. Kiểm tra `ping 10.10.10.50`, rồi sửa Host Override `k8s-api.hainth.local` trên pfSense sang `.50`. Trên các node có thể cần xoá cache DNS (`resolvectl flush-caches`). Chạy `kubectl get nodes` từ toolbox để xác nhận.
5. Terraform: xoá `kubew1`, `kubew2` khỏi tfvars, thêm `kubec2`, `kubec3`, rồi `apply` (plan đúng phải là: 2 to add, 2 to destroy).
6. Chạy role chuẩn bị, rồi join kubec2 và **chờ etcd ổn định** trước khi join kubec3. Gỡ taint và label cho cả hai.
7. Kiểm tra etcd:
   ```bash
   kubectl -n kube-system exec etcd-kubec1 -- etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key member list -w table
   ```

---

## 4. Bài tập
1. **Failover API:** chạy `watch -n1 kubectl get nodes` trong toolbox. Trên Proxmox, `qm stop 151` (kubec1, đang giữ VIP). Đo xem bao nhiêu giây sau thì `kubectl` chạy lại được. Trên kubec2, `ip a show ens18` có thấy `.50` không?
2. **Failover workload:** deploy nginx 3 replica kèm `topologySpreadConstraints` để mỗi node có 1 pod, và Service LoadBalancer. `curl` liên tục trong lúc tắt 1 node. Có request nào lỗi không? Pod của node chết được dựng lại sau bao lâu? (Gợi ý: tìm hiểu toleration mặc định `node.kubernetes.io/unreachable` có thời gian 300s.)
3. **Mất quorum:** tắt thêm kubec2 (chỉ còn kubec3). `kubectl get nodes` ra sao? Pod nginx còn trả lời không? Vì sao vẫn còn hoặc không còn? Sau đó bật lại cả hai.
4. **Leader election:** `kubectl -n kube-system get lease`. Ai đang là leader của `kube-scheduler`, `kube-controller-manager`, `plndr-cp-lock` (kube-vip)? Tắt node leader và quan sát lease chuyển sang node khác.
5. **Áp lực tài nguyên:** chạy một pod `stress` xin 2GB RAM, không đặt limit. Quan sát eviction, và kiểm tra apiserver và etcd có bị ảnh hưởng không. Sau đó thêm `LimitRange` cho namespace và chạy lại.
6. Viết lại `upgrade.yml` cho 3 control-plane: `kubeadm upgrade apply` trên kubec1, `kubeadm upgrade node` trên kubec2 và kubec3, `serial: 1`. Trước khi drain, kiểm tra 2 node còn lại đủ chỗ chứa workload.
7. Backup etcd trong cluster HA: snapshot từ 1 member là đủ chưa? Restore cluster 3 member thì quy trình khác gì so với 1 member? Tham khảo [docs etcd disaster recovery](https://etcd.io/docs/latest/op-guide/recovery/).

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| `kubeadm init` treo ở `waiting for the API server` khi bật HA | Gặp bẫy super-admin.conf (đường A, bước 4), hoặc sai tên interface trong manifest kube-vip |
| VIP không ping được | kube-vip pod lỗi. Trên cp, tìm container bằng `crictl ps -a --name kube-vip` rồi xem `crictl logs <id>` |
| Service LoadBalancer có IP nhưng không `curl` được | Còn label `exclude-from-external-load-balancers` (mục 2). Xem `kubectl -n metallb-system logs ds/metallb-speaker` |
| Pod `Pending` với lỗi `untolerated taint` | Chưa gỡ taint control-plane trên node mới join |
| Join control-plane báo `certificate-key` không hợp lệ | Key quá 2 giờ, cần sinh lại bằng `kubeadm init phase upload-certs --upload-certs` |
| etcd của node mới lỗi `member already exists` | Lần join trước thất bại giữa chừng. Xoá member cũ (`etcdctl member remove`) rồi `kubeadm reset` node đó |
| apiserver restart liên tục khi có tải | Workload ăn hết RAM. Kiểm tra `systemReserved`/`kubeReserved` và limit của app |

➡️ Tiếp theo: [08: Golden image](08-golden-image.md)
