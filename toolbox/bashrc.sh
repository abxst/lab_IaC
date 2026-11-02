# Cấu hình shell chung của toolbox. Được source từ /etc/bash.bashrc cho mọi shell tương tác
# (docker exec ... bash, terminal VS Code).

[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion

# Cache provider dùng chung giữa các thư mục Terraform, đỡ tải lại bpg/proxmox cho từng bài
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

source <(kubectl completion bash)
source <(helm completion bash)
complete -C /usr/local/bin/terraform terraform
complete -C /usr/local/bin/packer packer
alias k=kubectl
complete -o default -F __start_kubectl k

# Editor mặc định cho git commit, kubectl edit, ansible-vault edit...
export EDITOR=nano VISUAL=nano

# Tự nạp .envrc (token Proxmox, KUBECONFIG) khi cd vào repo
eval "$(direnv hook bash)"

PS1='\[\e[1;36m\](toolbox)\[\e[0m\] \u:\w\$ '
