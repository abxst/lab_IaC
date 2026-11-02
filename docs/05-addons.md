# Giai đoạn 5: Add-on bằng Terraform (helm + kubernetes provider)

Mục tiêu: dùng Terraform quản lý các thành phần chạy **bên trong** cluster:

| Add-on | Vai trò |
|---|---|
| **kubelet-csr-approver** | Tự duyệt serving cert của kubelet (thay cho việc duyệt tay ở giai đoạn 4) |
| **MetalLB** (L2) | Cấp IP thật trong LAN cho Service `type: LoadBalancer`. Bare-metal không có cloud LB |
| **metrics-server** | `kubectl top`, HPA |
| **Traefik** | Ingress controller + Gateway API |

Code sẽ nằm ở `infra/terraform/addons/`.

> Vì sao chọn Traefik mà không dùng ingress-nginx? Dự án **ingress-nginx đã ngừng phát triển** (SIG Network thông báo nghỉ hưu vào năm 2026). Traefik vẫn được phát triển tích cực và hỗ trợ cả Ingress lẫn Gateway API.

---

## 1. Ý tưởng chính: tách state theo lớp

```
infra/terraform/vms/      state A: VM, inventory          (thay đổi hiếm, rủi ro cao)
infra/terraform/addons/   state B: helm releases          (thay đổi thường xuyên)
```
- `destroy` lớp add-on **không** đụng tới VM.
- Lỗi ở helm chart không làm treo `plan` của hạ tầng.
- Khi làm nhóm, có thể phân quyền theo từng lớp.

Cái giá phải trả: Terraform không biết lớp B phụ thuộc vào lớp A, nên bạn phải chạy đúng thứ tự (`Makefile` sẽ lo việc này). Lớp B có thể đọc output của lớp A qua `terraform_remote_state`, hoặc đơn giản hơn, đọc file kubeconfig.

## 2. Cấu hình provider

```hcl
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "helm" {
  kubernetes = {                         # provider helm v3: đây là attribute (dùng "="), không còn là block
    config_path = pathexpand(var.kubeconfig)
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig)
}
```
> Từ helm provider **v3**, cú pháp đã đổi: `kubernetes = { ... }` và `set = [ { name = ..., value = ... } ]` thay cho các block lặp lại. Nhiều blog cũ vẫn viết theo cú pháp v2, nên khi `validate` báo lỗi hãy kiểm tra version provider trước.

## 3. Các release

```hcl
resource "helm_release" "csr_approver" {
  name       = "kubelet-csr-approver"
  repository = "https://postfinance.github.io/kubelet-csr-approver"
  chart      = "kubelet-csr-approver"
  version    = var.chart_versions.csr_approver
  namespace  = "kube-system"
  values = [yamlencode({
    providerRegex       = "^kube[cw][0-9]+$"   # chỉ duyệt cho node kubecN / kubewN
    providerIpPrefixes  = ["10.10.10.0/24"]
    bypassDnsResolution = true                 # lab không có DNS cho tên node
  })]
}

resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.chart_versions.metallb
  namespace        = "metallb-system"
  create_namespace = true
  wait             = true
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  namespace  = "kube-system"
  depends_on = [helm_release.csr_approver]     # cần serving cert hợp lệ của kubelet
}

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.chart_versions.traefik
  namespace        = "traefik"
  create_namespace = true
  depends_on       = [helm_release.metallb_pools]  # cần pool để Service nhận được IP
}
```
**Luôn pin `version` cho chart.** Không pin thì mỗi lần `apply` có thể kéo về một bản mới, mà bạn không hề hay biết.

## 4. Bẫy CRD: tạo IPAddressPool cho MetalLB

MetalLB cần 2 custom resource là `IPAddressPool` và `L2Advertisement`. Cách hiển nhiên nhất là dùng `kubernetes_manifest`, nhưng cách đó **lỗi ở lần apply đầu tiên**: `kubernetes_manifest` phải kiểm tra CRD **ngay lúc plan**, trong khi CRD chỉ xuất hiện sau khi MetalLB được cài xong.

Các cách xử lý:

| Cách | Đánh giá |
|---|---|
| `terraform apply -target=helm_release.metallb` rồi mới `apply` toàn bộ | Chạy được, nhưng `-target` là thao tác thủ công, không nên đưa vào quy trình |
| Tách sang một state thứ 3 | Sạch sẽ, nhưng lab nhỏ thì hơi thừa |
| **Đóng 2 CR vào một chart nhỏ ngay trong repo**, cài bằng `helm_release` | ✅ Lab dùng cách này. Helm không kiểm tra CRD lúc plan |

```
infra/terraform/addons/charts/metallb-pools/
├── Chart.yaml
└── templates/pool.yaml      # IPAddressPool {{ .Values.range }} + L2Advertisement
```
```hcl
resource "helm_release" "metallb_pools" {
  name       = "metallb-pools"
  chart      = "${path.module}/charts/metallb-pools"
  namespace  = "metallb-system"
  values     = [yamlencode({ range = var.metallb_range })]   # "10.10.10.80-10.10.10.99"
  depends_on = [helm_release.metallb]
}
```

## 5. Chạy
```bash
cd infra/terraform/addons
terraform init && terraform apply
kubectl -n traefik get svc traefik      # EXTERNAL-IP = 10.10.10.80
kubectl top nodes
```

## 6. Bài tập
1. **LoadBalancer:** `kubectl create deploy web --image=nginx && kubectl expose deploy web --port 80 --type LoadBalancer`. Service nhận IP nào? `curl` thử từ toolbox, rồi mở bằng trình duyệt trên Jump. ❓ Vì sao từ laptop chính (ngoài mạng lab) lại không vào được IP này? Muốn vào được thì cần thêm gì? (Gợi ý: Tailscale subnet router, hoặc NAT/port forward trên pfSense.)
2. **Ingress không cần DNS:** viết Ingress `whoami.10.10.10.80.nip.io` cho image `traefik/whoami` (dùng `kubernetes_deployment`, `kubernetes_service`, `kubernetes_ingress_v1` trong Terraform). Mở link này trên trình duyệt.
3. **Gateway API:** bật Gateway provider trong values của Traefik, viết `Gateway` + `HTTPRoute` thay cho Ingress. So sánh hai cách.
4. **Drift:** `helm upgrade` tay một release (đổi replicas), rồi `terraform plan`. Terraform có phát hiện được không?
5. **Nâng version chart:** tăng `chart_versions.traefik`, đọc kỹ `plan`, rồi `apply`.
6. **HPA:** tạo HPA cho `web` theo CPU, rồi tạo tải bằng `kubectl run load --image=busybox -- sh -c "while true; do wget -qO- http://web; done"`.

## Lỗi thường gặp
| Triệu chứng | Cách xử lý |
|---|---|
| Service `EXTERNAL-IP <pending>` | Chưa có `IPAddressPool`/`L2Advertisement`, hoặc dải IP sai subnet |
| Có IP nhưng `curl` không tới | IP trùng với thiết bị khác (dải nằm trong DHCP của pfSense). Xem *Diagnostics → ARP Table* trên pfSense: IP của MetalLB phải trỏ tới MAC của một node K8s |
| `kubectl top` lỗi `Metrics API not available` | CSR kubelet-serving chưa được duyệt. Kiểm tra `kubectl get csr` và log của kubelet-csr-approver |
| Helm báo `cannot re-use a name that is still in use` | Release đã được cài tay trước đó. Dùng khối `import {}` hoặc `helm uninstall` trước |

➡️ Tiếp theo: [06: Day-2 operations](06-day2-operations.md)
