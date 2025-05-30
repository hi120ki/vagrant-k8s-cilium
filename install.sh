#!/bin/bash -eu

cd "$(dirname "$0")"

cmd=$(basename "$0")
if [ $# -ne 4 ]; then
  echo "Usage: $cmd address interface ipstart ipstop" 1>&2
  exit 1
fi

sudo apt-get update && sudo apt-get install -y yq moreutils

# https://github.com/helm/helm
echo "[i] install helm"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh

# https://github.com/ahmetb/kubectl-aliases
echo "[i] add shell alias"
curl -fsSL "https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases" -o ~/.kubectl_aliases
echo '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' >>~/.bashrc
echo 'function kubectl() { echo "+ kubectl $@">&2; command kubectl $@; }' >>~/.bashrc

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#install-and-configure-prerequisites
echo "[i] network config"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
sysctl net.ipv4.ip_forward

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd
echo "[i] install containerd"
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y containerd.io
sudo mkdir -p /etc/containerd
containerd config default |
  sed -e "s/SystemdCgroup = false/SystemdCgroup = true/g" |
  sed -e "s/registry.k8s.io\/pause:3.8/registry.k8s.io\/pause:3.10/g" |
  sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
echo "[i] install kubeadm"
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "[i] kubeadm init"
sudo kubeadm init \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=NumCPU \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address "$1"

mkdir -p "$HOME"/.kube
sudo cp -f /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

for i in {10..1}; do
  echo "[i] waiting kubeadm init $i"
  sleep 1
done

c1=$(kubectl get pods -A | grep -c "Running") || true
c2=$(kubectl get pods -A | grep -c "Pending") || true
while [ "$c1" -ne 4 ] || [ "$c2" -ne 2 ]; do
  sleep 1
  echo "[i] waiting coredns pending"
  c1=$(kubectl get pods -A | grep -c "Running") || true
  c2=$(kubectl get pods -A | grep -c "Pending") || true
done
echo "[+] coredns pending done"

# https://github.com/cilium/cilium
# https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
echo "[i] install cilium cli"
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -s -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/"${CILIUM_CLI_VERSION}"/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# https://github.com/cilium/cilium/blob/main/install/kubernetes/cilium/values.yaml
cat <<EOF > /tmp/cilium-values.yaml
l2announcements:
  enabled: true

k8sClientRateLimit:
  qps: 50
  burst: 100

kubeProxyReplacement: true
k8sServiceHost: $1
k8sServicePort: 6443

operator:
  replicas: 1

hubble:
  enabled: false
EOF

cilium install --helm-values /tmp/cilium-values.yaml
cilium status --wait

echo "[i] taint node"
kubectl taint node --all node-role.kubernetes.io/control-plane:NoSchedule-

echo "[i] node info"
kubectl get nodes -o wide

echo "[i] enable hostpath provisioner"
if [ ! -e "/etc/kubernetes/manifests/kube-controller-manager.yaml" ]; then
  echo "File does not exist: /etc/kubernetes/manifests/kube-controller-manager.yaml" 1>&2
  exit 1
fi
sudo cat /etc/kubernetes/manifests/kube-controller-manager.yaml |
  yq -e '.spec.containers[].command += ["--enable-hostpath-provisioner=true"]' |
  sudo sponge /etc/kubernetes/manifests/kube-controller-manager.yaml

echo "[i] add storageclass"
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: standard
  annotations:
    storageclass.beta.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/host-path
EOF

echo "[i] show all pods"
kubectl get pods --all-namespaces

# https://blog.stonegarden.dev/articles/2023/12/migrating-from-metallb-to-cilium/
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2-announcement-policy
spec:
  interfaces:
    - $2
  externalIPs: true
  loadBalancerIPs: true
EOF

cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-loadbalancer-ip-pool
spec:
  blocks:
    - start: $3
      stop: $4
EOF

echo "[+] all done"
