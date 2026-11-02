# syntax=docker/dockerfile:1
#
# Toolbox = control node của lab: terraform, packer, ansible, kubectl, helm.
# Chạy trên host Dokploy (super-nginx) bằng docker compose, xem toolbox/README.md.
# Mọi version đều pin bằng ARG; muốn nâng thì sửa ARG rồi build lại.
# Bí mật (token Proxmox, SSH key) KHÔNG nằm trong image, chỉ nằm trên volume /home/devops.

FROM ubuntu:24.04

ARG TERRAFORM_VERSION=1.17.1
ARG PACKER_VERSION=1.16.2
ARG KUBECTL_VERSION=v1.36.6
ARG HELM_VERSION=v4.3.1
ARG ANSIBLE_VERSION=14.5.0
ARG ANSIBLE_LINT_VERSION=26.10.1
ARG PY_KUBERNETES_VERSION=37.0.1
ARG USERNAME=devops
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Ho_Chi_Minh

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git make jq openssh-client rsync less vim-tiny \
      bash-completion direnv xorriso sshpass sudo tzdata \
      python3 python3-venv \
      iputils-ping dnsutils netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# Binary chính thức, luôn kiểm tra checksum trước khi cài
WORKDIR /tmp/install
RUN for tool in terraform:${TERRAFORM_VERSION} packer:${PACKER_VERSION}; do \
      name=${tool%%:*}; ver=${tool##*:}; \
      curl -fsSLO "https://releases.hashicorp.com/${name}/${ver}/${name}_${ver}_linux_amd64.zip"; \
      curl -fsSL "https://releases.hashicorp.com/${name}/${ver}/${name}_${ver}_SHA256SUMS" | grep linux_amd64.zip | sha256sum -c -; \
      unzip -o "${name}_${ver}_linux_amd64.zip" "${name}" -d /usr/local/bin; \
    done \
 && curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  kubectl" | sha256sum -c - \
 && install -m 0755 kubectl /usr/local/bin/kubectl \
 && curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
 && curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
 && sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
 && tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64/helm \
 && install -m 0755 linux-amd64/helm /usr/local/bin/helm \
 && cd / && rm -rf /tmp/install
WORKDIR /

# Ansible trong venv riêng; thư viện kubernetes cho collection kubernetes.core (giai đoạn 4+)
RUN python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir \
      "ansible==${ANSIBLE_VERSION}" \
      "ansible-lint==${ANSIBLE_LINT_VERSION}" \
      "kubernetes==${PY_KUBERNETES_VERSION}"
ENV PATH="/opt/ansible/bin:${PATH}"

# User thường. Image ubuntu:24.04 có sẵn user "ubuntu" với UID 1000, xoá đi để dùng UID đó.
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && groupadd -g "${GID}" "${USERNAME}" \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}" \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Cấu hình shell đặt trong /etc, vì /home/devops bị volume che mất
COPY bashrc.sh /etc/toolbox/bashrc.sh
RUN echo 'source /etc/toolbox/bashrc.sh' >> /etc/bash.bashrc

USER ${USERNAME}
WORKDIR /home/${USERNAME}
CMD ["sleep", "infinity"]
