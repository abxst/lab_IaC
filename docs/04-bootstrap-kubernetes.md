# Giai đoạn 4: Bootstrap Kubernetes bằng Ansible + kubeadm

Mục tiêu: một lệnh `ansible-playbook playbooks/site.yml` biến 3 VM trắng thành cluster gồm 1 control-plane và 2 worker, `Ready`, có CNI. Chạy lại lần 2 phải ra `changed=0`.

Code sẽ nằm ở `ansible/roles/` và `ansible/playbooks/site.yml`.

---

## 1. kubeadm làm những gì khi `init` và `join`?

```
kubeadm init (trên kubec1)
 1. preflight      kiểm tra swap, port, sysctl, container runtime
 2. certs          tạo CA + cert tại /etc/kubernetes/pki/
 3. kubeconfig     admin.conf, kubelet.conf, controller-manager.conf, scheduler.conf
 4. static pods    ghi manifest vào /etc/kubernetes/manifests/
                   (etcd, kube-apiserver, kube-controller-manager, kube-scheduler)
                   → kubelet thấy file và tự chạy các pod này
 5. bootstrap      tạo token để node khác join
 6. addons         CoreDNS + kube-proxy
   ⚠ node vẫn NotReady cho tới khi có CNI

kubeadm join (trên worker)
 dùng token + hash của CA → kubelet xin cert (TLS bootstrap) → node đăng ký vào cluster
```
Hiểu sơ đồ này thì khi cluster lỗi, bạn sẽ biết cần nhìn vào đâu.

## 2. Điều kiện tiên quyết trên mọi node: role `common`

| Yêu cầu | Lý do | Task Ansible |
|---|---|---|
| Hostname duy nhất, `/etc/hosts` có đủ các node | Node đăng ký vào cluster bằng hostname. Tên `k8s-api.hainth.local` do pfSense phân giải (xem mục 5) | `ansible.builtin.hostname`, template `hosts.j2` |
| **Tắt swap** | Mặc định kubelet từ chối chạy khi có swap | `command: swapoff -a` (kèm `when`) + bỏ dòng swap trong fstab. Template đã tắt sẵn, đây chỉ là lớp bảo vệ thêm |
| Kernel module `overlay`, `br_netfilter` | overlayfs cho container; traffic qua bridge phải đi qua iptables | `community.general.modprobe` + file `/etc/modules-load.d/k8s.conf` |
| sysctl `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-iptables=1`, `net.bridge.bridge-nf-call-ip6tables=1` | Pod network cần định tuyến | `ansible.posix.sysctl` |
| Đồng bộ thời gian (chrony) | Cert và etcd rất nhạy với lệch giờ | role chrony đã viết ở giai đoạn 2 |
| `machine-id` / `product_uuid` duy nhất | kubeadm preflight kiểm tra điều này | Đã xử lý ở bước generalize của giai đoạn 3 |

Task đầu tiên của play nên đợi cloud-init chạy xong, để tránh tranh khoá apt:
```yaml
- name: Đợi cloud-init xong
  ansible.builtin.command: cloud-init status --wait
  changed_when: false
```

## 3. Container runtime: role `containerd`

- Kubernetes nói chuyện với runtime qua **CRI**. containerd là lựa chọn phổ biến nhất.
- Nên dùng gói **`containerd.io` từ repo Docker** (containerd 2.x). Gói `containerd` của Ubuntu 24.04 là bản 1.7, và các bản K8s mới đang dần bỏ hỗ trợ containerd 1.x. Hãy kiểm tra release notes của minor bạn chọn.
- **Cgroup driver phải khớp nhau:** kubelet (mặc định từ kubeadm là `systemd`) và containerd (`SystemdCgroup = true`).

```yaml
- name: Sinh config mặc định (gói containerd.io mặc định TẮT plugin CRI!)
  ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
  args:
    creates: /etc/containerd/.generated
  notify: Restart containerd
  # ... rồi touch file .generated để đánh dấu đã sinh config

- name: Bật SystemdCgroup
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'
  notify: Restart containerd
```
> **Bẫy hay gặp:** file `config.toml` đi kèm gói `containerd.io` có dòng `disabled_plugins = ["cri"]`. Không sinh lại config thì kubeadm báo `container runtime is not running`.
> Khi code thật, nên dùng template `config.toml.j2` thay cho `shell` + `replace`. Ở đây tách ra từng bước để bạn thấy rõ cần sửa gì.

Kiểm tra trên node: `sudo crictl info | grep -i systemdcgroup`. Cần có file `/etc/crictl.yaml` trỏ tới `unix:///run/containerd/containerd.sock`.

## 4. kubeadm, kubelet, kubectl: role `kube_packages`

```yaml
# group_vars/all.yml
k8s_minor: "v1.36"         # repo pkgs.k8s.io tách theo minor
k8s_version: "1.36.6"      # patch cụ thể (khớp kubectl trong tools/install-tools.sh), xem https://kubernetes.io/releases/
```
- Thêm repo `https://pkgs.k8s.io/core:/stable:/{{ k8s_minor }}/deb/` (repo chính thức, mỗi minor version là một repo riêng).
- Cài **đúng version**: `kubeadm={{ k8s_version }}-*`, tương tự cho kubelet và kubectl.
- **Hold** các gói để `apt upgrade` không lỡ tay nâng K8s:
  ```yaml
  - ansible.builtin.dpkg_selections:
      name: "{{ item }}"
      selection: hold
    loop: [kubeadm, kubelet, kubectl]
  ```
  Chỉ playbook `upgrade.yml` ở giai đoạn 6 được unhold.

## 5. Control plane: role `control_plane`

### kubeadm config (template `kubeadm-config.yaml.j2`)
```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "{{ ansible_host }}"
nodeRegistration:
  name: "{{ inventory_hostname }}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v{{ k8s_version }}"
clusterName: k8s-lab
controlPlaneEndpoint: "{{ control_plane_endpoint }}:6443"   # k8s-api.hainth.local, xem ghi chú bên dưới
networking:
  podSubnet: "{{ pod_cidr }}"          # 10.244.0.0/16
  serviceSubnet: "{{ service_cidr }}"  # 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true               # kubelet xin serving cert hợp lệ (giai đoạn 5 cần cho metrics-server)
```
> ⚠️ **Pod CIDR và Service CIDR không được trùng với bất kỳ mạng nào mà node cần đi tới.** Trong lab này, các mạng đó gồm LAN `10.10.10.0/24`, WAN của pfSense `172.16.100.0/24` và **mạng nhà `192.168.1.0/24`** (đường ra Internet của Proxmox).
> Vì vậy **không dùng mặc định của Calico (`192.168.0.0/16`)**: dải đó bao trùm mạng nhà, khiến gói tin từ node đi tới router nhà bị hút vào mạng pod. `10.244.0.0/16` và `10.96.0.0/12` không trùng với mạng nào ở trên.

> **`controlPlaneEndpoint` nên là tên DNS, không nên là IP**, và phải đặt ngay từ lần `init` đầu tiên. Lý do: tên này được ghi vào cert của API server và vào mọi kubeconfig. Sau `init` thì đổi rất khó.
> - Lab dùng `control_plane_endpoint: k8s-api.hainth.local`, khai báo bằng **Host Override trên pfSense** (giai đoạn 0, Phần A). Node dùng DNS `10.10.10.254`, còn Jump và WSL cũng đi qua pfSense, nên không cần sửa `/etc/hosts` ở đâu cả.
> - Lên HA ở giai đoạn 7, chỉ cần sửa Host Override sang VIP `10.10.10.50`, không phải dựng lại cluster.

### Các task chính
```yaml
- name: Kiểm tra đã init chưa
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: admin_conf

- name: kubeadm init
  ansible.builtin.command: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
  when: not admin_conf.stat.exists

- name: Kéo kubeconfig về WSL
  ansible.builtin.fetch:
    src: /etc/kubernetes/admin.conf
    dest: ~/.kube/k8s-lab.conf
    flat: true
```
File `.envrc` (trong WSL) đã có sẵn `export KUBECONFIG=$HOME/.kube/k8s-lab.conf` (xem `.envrc.example`). Kubeconfig của cluster khác (nếu có) sẽ không bị ghi đè.

## 6. CNI: role `cni` (Calico)

- Cài **Tigera operator**, sau đó tạo resource `Installation` với `cidr` bằng `pod_cidr`.
- Nên chạy từ WSL bằng `kubernetes.core.k8s` (`delegate_to: localhost`). Cách này cần thư viện Python `kubernetes` trong venv của Ansible. `tools/install-tools.sh` đã cài sẵn thư viện này vào `/opt/ansible`.
- Manifest của operator có CRD rất lớn, `apply` kiểu client-side sẽ lỗi `metadata.annotations: Too long`. Hãy dùng **server-side apply**:
  ```yaml
  - kubernetes.core.k8s:
      src: /tmp/tigera-operator.yaml
      state: present
      server_side_apply:
        field_manager: ansible
  ```
- `Installation` tối thiểu:
  ```yaml
  apiVersion: operator.tigera.io/v1
  kind: Installation
  metadata:
    name: default
  spec:
    calicoNetwork:
      ipPools:
        - cidr: 10.244.0.0/16
          encapsulation: VXLANCrossSubnet
          natOutgoing: Enabled
  ```
- Chờ đến khi các node `Ready` (`kubernetes.core.k8s_info` + `wait_condition`, hoặc `kubectl wait --for=condition=Ready nodes --all --timeout=300s`).

Version Calico: pin bản mới nhất trên https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements, nhớ kiểm tra bảng tương thích với minor K8s bạn đang dùng.

## 7. Worker: role `worker`

```yaml
- name: Lấy lệnh join từ control plane
  ansible.builtin.command: kubeadm token create --print-join-command
  delegate_to: "{{ groups['control_plane'][0] }}"
  run_once: true
  register: join_cmd
  changed_when: false

- name: Join cluster
  ansible.builtin.command: "{{ join_cmd.stdout }}"
  args:
    creates: /etc/kubernetes/kubelet.conf
```
Token mặc định hết hạn sau 24 giờ. Vì mỗi lần chạy ta tạo token mới, playbook luôn chạy được.

### Duyệt serving cert của kubelet
Vì đã bật `serverTLSBootstrap: true`, mỗi kubelet sẽ gửi một CSR `kubernetes.io/kubelet-serving` và **chờ được duyệt**. Nếu chưa duyệt, `kubectl logs` và `kubectl exec` sẽ báo lỗi TLS. Thêm một task chạy sau khi các node đã join:
```bash
kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving
kubectl get csr -o name --field-selector spec.signerName=kubernetes.io/kubelet-serving | xargs -r kubectl certificate approve
```
Cert này sẽ được xoay vòng định kỳ, mỗi lần lại sinh CSR mới. Ở giai đoạn 5, ta cài `kubelet-csr-approver` để tự động duyệt (chỉ duyệt CSR có hostname/IP khớp với node), thay cho việc duyệt tay.

## 8. `site.yml`

```yaml
- name: Chuẩn bị mọi node
  hosts: k8s_cluster
  become: true
  roles: [common, containerd, kube_packages]

- name: Control plane
  hosts: control_plane
  become: true
  roles: [control_plane]

- name: CNI
  hosts: control_plane[0]
  roles: [cni]

- name: Worker
  hosts: workers
  become: true
  roles: [worker]
```

---

## 9. Kiểm tra
```bash
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/site.yml     # lần 2: changed=0

kubectl get nodes -o wide              # 3 node Ready, đúng version
kubectl get pods -A                    # tất cả Running
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
kubectl create deployment web --image=nginx --replicas=3
kubectl get pods -o wide               # pod rải trên 2 worker, IP trong 10.244.x.x
```

## 10. Bài tập
1. SSH vào `kubec1`, xem `/etc/kubernetes/manifests/`. Thử di chuyển `kube-scheduler.yaml` ra chỗ khác rồi tạo một pod mới. Pod đó sẽ ở trạng thái gì? Vì sao? Sau đó trả file về chỗ cũ.
2. `sudo systemctl stop kubelet` trên `kubew1`. Sau khoảng 40 giây node chuyển trạng thái gì? Các pod trên node đó bị xử lý thế nào sau 5 phút?
3. `kubeadm certs check-expiration`: các cert hết hạn khi nào? Cert của CA thì sao?
4. Phá cluster bằng `kubeadm reset -f` trên mọi node (playbook `reset.yml`) → chạy lại `site.yml` → cluster dựng lại sạch.
5. Viết thêm role `node_labels`, gán label `node-role.kubernetes.io/worker=` cho các worker.
6. Thử NetworkPolicy deny-all trong namespace `demo`, rồi mở dần cho từng pod.

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| `[ERROR CRI]: container runtime is not running` | Config containerd vẫn còn `disabled_plugins = ["cri"]`, phải sinh lại config |
| kubelet restart liên tục, log báo cgroup | `SystemdCgroup` chưa bật, hoặc không khớp với kubelet |
| Node `NotReady` mãi | Chưa có CNI, hoặc CIDR của Calico khác `podSubnet`. Xem `kubectl -n calico-system get pods` |
| Pod không ra được Internet | Pod CIDR trùng LAN, hoặc `natOutgoing` tắt |
| `join` báo `token expired` hoặc `certificate signed by unknown authority` | Token cũ. Playbook phải tạo token mới mỗi lần chạy |
| `kubectl logs/exec` lỗi `tls: internal error` | Có CSR kubelet-serving chưa duyệt, xem mục 7 |
| CoreDNS `CrashLoopBackOff` | `/etc/resolv.conf` của node trỏ về `127.0.0.53` gây loop. Cấu hình `resolvConf: /run/systemd/resolve/resolv.conf` trong KubeletConfiguration |

➡️ Tiếp theo: [05: Add-on bằng Terraform](05-addons.md)
