# Giai đoạn 2: Ansible cơ bản

Mục tiêu: viết được playbook và role **idempotent**, tức là chạy 1 lần hay 10 lần thì kết quả vẫn như nhau. Đây là kỹ năng cốt lõi để ở giai đoạn 4 cài Kubernetes mà không làm hỏng cluster mỗi lần chạy lại.

Môi trường thực hành: VM `tf-sandbox` (`10.10.10.59`) tạo ở bài 7 của giai đoạn 1. Nếu chưa có, chạy lại bài đó.
Code sẽ nằm ở `labs/ansible-basics/`.

---

## 1. Terraform và Ansible: ai làm gì?

| | Terraform | Ansible |
|---|---|---|
| Mô hình | Khai báo + **state** | Khai báo từng task, **không có state** (mỗi lần chạy đều kiểm tra thực tế) |
| Mạnh ở | Tạo, xoá **hạ tầng** qua API (VM, network, DNS) | Cấu hình **bên trong** máy qua SSH (package, file, service) |
| Trong lab | Tạo VM, sinh inventory, cài helm release | Cài containerd, kubeadm, init/join cluster, Day-2 |

Hai công cụ có vùng chồng lấn (Ansible cũng tạo được VM, Terraform cũng chạy được script), nhưng chia việc như trên là cách phổ biến và dễ bảo trì nhất.

## 2. Khái niệm cốt lõi

### Kiến trúc agentless
Control node (WSL) SSH vào managed node, đẩy module Python sang, chạy, lấy kết quả JSON về rồi xoá module. Managed node chỉ cần **SSH + Python 3**, không phải cài agent.

### Inventory
```ini
# inventory/hosts.ini
[sandbox]
tf-sandbox ansible_host=10.10.10.59

[sandbox:vars]
ansible_user=ansible
```
```bash
ansible-inventory -i inventory/hosts.ini --graph
ansible-inventory -i inventory/hosts.ini --list   # dạng JSON, thấy hết biến
```

### `ansible.cfg`
```ini
[defaults]
inventory         = inventory/hosts.ini
remote_user       = ansible
private_key_file  = ~/.ssh/k8s_lab
host_key_checking = False
stdout_callback   = ansible.builtin.default
callback_result_format = yaml # output dễ đọc hơn
forks             = 10

[ssh_connection]
pipelining = True             # nhanh hơn rõ rệt
```
> Ansible tìm `ansible.cfg` theo thứ tự: biến `ANSIBLE_CONFIG` → thư mục hiện tại → `~/.ansible.cfg` → `/etc/ansible/ansible.cfg`. Nó **bỏ qua** `ansible.cfg` nằm trong thư mục world-writable (quyền 777), ví dụ ổ Windows mount vào WSL. Đó là lý do repo phải được chép vào `~/devopvips` trong WSL (giai đoạn 0, bước C2).

### Lệnh ad-hoc: chạy nhanh một module
```bash
ansible all -m ansible.builtin.ping
ansible all -m ansible.builtin.setup -a 'filter=ansible_distribution*'   # facts
ansible all -b -m ansible.builtin.apt -a 'name=htop state=present'      # -b = become (sudo)
```

### Playbook → Play → Task → Module
```yaml
# playbooks/hello.yml
- name: Cấu hình cơ bản          # PLAY: áp lên nhóm host nào, với quyền gì
  hosts: sandbox
  become: true
  tasks:                          # TASK: gọi một MODULE kèm tham số
    - name: Cài gói cơ bản
      ansible.builtin.apt:
        name: [curl, htop, chrony]
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Đảm bảo chrony chạy
      ansible.builtin.service:
        name: chrony
        state: started
        enabled: true
```
Luôn dùng **FQCN** (tên đầy đủ, ví dụ `ansible.builtin.apt`). ansible-lint sẽ nhắc nếu bạn quên.

### Idempotency: `changed` vs `ok`
- `ok`: thực tế đã đúng như mong muốn, không làm gì.
- `changed`: đã phải sửa để đạt trạng thái mong muốn.
- Chạy lại một playbook đúng chuẩn thì kết quả phải là **`changed=0`**.

Module `command`/`shell` **không biết** trạng thái, lần nào chạy cũng báo `changed`. Khi buộc phải dùng chúng, hãy kèm điều kiện:
```yaml
- name: Init chỉ một lần
  ansible.builtin.command: kubeadm init --config /etc/kubeadm.yaml
  args:
    creates: /etc/kubernetes/admin.conf      # file đã tồn tại thì bỏ qua

- name: Đọc version (chỉ đọc)
  ansible.builtin.command: kubeadm version -o short
  register: kv
  changed_when: false                        # chỉ đọc, không bao giờ là "changed"
```

### Biến và thứ tự ưu tiên (rút gọn)
Thứ tự từ thấp lên cao: `role defaults` < `group_vars/all` < `group_vars/<group>` < `host_vars/<host>` < `vars:` trong play < `set_fact`/`register` < `-e` trên dòng lệnh (luôn thắng).

Quy ước của repo này: giá trị mặc định đặt ở `roles/<role>/defaults/main.yml`, giá trị riêng của lab đặt ở `inventory/group_vars/`.

### Handler: chỉ restart khi có thay đổi
```yaml
tasks:
  - name: Cấu hình chrony
    ansible.builtin.template:
      src: chrony.conf.j2
      dest: /etc/chrony/chrony.conf
      mode: "0644"
    notify: Restart chrony         # chỉ kích hoạt khi task này "changed"

handlers:
  - name: Restart chrony
    ansible.builtin.service:
      name: chrony
      state: restarted
```

### Template Jinja2
```jinja
{# templates/hosts.j2 #}
127.0.0.1 localhost
{% for h in groups['all'] %}
{{ hostvars[h].ansible_host }} {{ h }}
{% endfor %}
```

### Loop, điều kiện, tag
```yaml
- name: Nạp kernel module
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop: [overlay, br_netfilter]
  when: ansible_facts['os_family'] == "Debian"
  tags: [kernel]
```
```bash
ansible-playbook site.yml --tags kernel        # chỉ chạy task có tag kernel
ansible-playbook site.yml --check --diff        # dry-run + xem diff file
ansible-playbook site.yml --limit tf-sandbox    # chỉ chạy trên một host
ansible-playbook site.yml --start-at-task "Cấu hình chrony"
```

### Role: cấu trúc chuẩn
```
roles/nginx/
├── defaults/main.yml     # biến mặc định (ưu tiên thấp nhất, cho phép ghi đè)
├── vars/main.yml         # hằng số nội bộ (ưu tiên cao, hiếm khi cần)
├── tasks/main.yml
├── handlers/main.yml
├── templates/            # *.j2
├── files/                # file tĩnh
└── meta/main.yml         # metadata, phụ thuộc giữa các role
```
```bash
ansible-galaxy role init roles/nginx    # sinh khung
```

### Collection
Module ngoài `ansible.builtin` nằm trong các collection. Lab sẽ dùng:
```bash
ansible-galaxy collection install community.general ansible.posix kubernetes.core
```
Repo sẽ có file `ansible/requirements.yml` để cài các collection này bằng một lệnh.

---

## 3. Bài tập

### Bài 1: Inventory và ad-hoc
- Tạo `ansible.cfg` và `inventory/hosts.ini` cho `tf-sandbox`.
- Chạy `ping`, xem facts (`setup`) và lọc ra RAM, CPU, IP.
- ❓ Vì sao `ansible all -m ping` không phải là ping ICMP?

### Bài 2: Playbook đầu tiên
- Viết playbook cài `curl htop chrony`, đặt timezone `Asia/Ho_Chi_Minh` (`community.general.timezone`), tạo user `devops`.
- Chạy 2 lần liên tiếp. Lần 2 phải ra `changed=0`.

### Bài 3: Template và handler
- Sinh `/etc/motd` từ template, hiển thị hostname, IP, OS (lấy từ facts).
- Thay config chrony bằng template trỏ tới `pool vn.pool.ntp.org`, kèm handler restart.
- Chạy với `--check --diff` trước, rồi mới chạy thật.
- Sửa file bằng tay trên VM, rồi chạy lại: Ansible phải đưa file về đúng và restart service.

### Bài 4: Biến và group_vars
- Đưa danh sách package và NTP server ra `group_vars/sandbox.yml`.
- Ghi đè một biến bằng `-e` và xem thứ tự ưu tiên hoạt động thế nào.

### Bài 5: Role nginx (bài tổng hợp)
- Role `nginx`:
  - `defaults`: `nginx_port: 80`, `nginx_server_name`, `nginx_root`;
  - `tasks`: cài, cấu hình site từ template, đảm bảo service chạy;
  - `handlers`: `reload nginx`;
  - có task kiểm tra `uri` gọi `http://{{ ansible_host }}:{{ nginx_port }}` trả về 200.
- Đổi `nginx_port: 8080` → chỉ cấu hình thay đổi, nginx được reload (không phải restart), trang vẫn chạy.
- `ansible-lint` phải không còn cảnh báo.

### Bài 6: `command` an toàn
- Viết task "khởi tạo một lần": tạo file `/opt/app/.initialized` bằng `command`, dùng `creates:`.
- Viết task đọc `uname -r`, dùng `register` + `changed_when: false`, rồi in ra bằng `debug`.
- ❓ Khi nào được dùng `shell` thay cho `command`? (Gợi ý: chỉ khi cần pipe hoặc redirect. `shell` có rủi ro injection.)

### Bài 7 (bonus): Ansible Vault
- Mã hoá một biến bí mật: `ansible-vault encrypt_string 'S3cret' --name db_password`.
- Dùng biến đó trong template, chạy với `--ask-vault-pass`.

Sau khi xong, chạy `terraform destroy` ở bài 7 giai đoạn 1 để xoá `tf-sandbox`.

---

## 4. Tự kiểm tra
1. Playbook chạy lần 2 vẫn còn `changed=3`. Bạn sẽ tìm nguyên nhân thế nào?
2. Khác nhau giữa `defaults/` và `vars/` trong role?
3. Handler được chạy vào lúc nào? Làm sao ép handler chạy ngay giữa play? (Gợi ý: `meta: flush_handlers`.)
4. Vì sao nên tránh `shell: apt-get install ...` dù nó vẫn "chạy được"?
5. `--check` có đáng tin 100% với task `command` không?

## Tài liệu đọc thêm
- https://docs.ansible.com/ansible/latest/playbook_guide/
- https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html
- https://ansible.readthedocs.io/projects/lint/

➡️ Tiếp theo: [03: Image + VM bằng code](03-vm-provisioning.md)
