#!/bin/bash -eu

cd $(dirname $0)

cmd=$(basename $0)
if [ $# -ne 1 ]; then
  echo "Usage: $cmd address" 1>&2
  exit 1
fi

sudo snap install yq

# https://github.com/helm/helm
echo "[i] install helm"
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
/tmp/get_helm.sh

# https://github.com/ahmetb/kubectl-aliases
echo "[i] add shell alias"
curl -fsSL "https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases" -o ~/.kubectl_aliases
echo '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' >>~/.bashrc
echo 'function kubectl() { echo "+ kubectl $@">&2; command kubectl $@; }' >>~/.bashrc
if [ -f ~/.config/fish/config.fish ]; then
  curl -fsSL "https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases.fish" -o ~/.kubectl_aliases.fish
  echo 'test -f ~/.kubectl_aliases.fish && source ~/.kubectl_aliases.fish' >>~/.config/fish/config.fish
fi

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#install-and-configure-prerequisites
echo "[i] network config"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep br_netfilter
lsmod | grep overlay

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd
echo "[i] install containerd"
# Add Docker's official GPG key
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# Add the repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
# Install containerd
sudo apt-get install -y containerd.io
containerd config default |
  sed -e "s/SystemdCgroup = false/SystemdCgroup = true/g" |
  sed -e "s/registry.k8s.io\/pause:3.6/registry.k8s.io\/pause:3.9/g" |
  sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
echo "[i] install kubeadm"
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "[i] kubeadm init"
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address $1

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

for i in {10..1}; do
  echo "[i] waiting kubeadm init $i"
  sleep 1
done

c1=$(kubectl get pods -A | grep -c "Running") || true
c2=$(kubectl get pods -A | grep -c "Pending") || true
while [ $c1 -ne 5 ] || [ $c2 -ne 2 ]; do
  sleep 1
  echo "[i] waiting coredns pending"
  c1=$(kubectl get pods -A | grep -c "Running") || true
  c2=$(kubectl get pods -A | grep -c "Pending") || true
done
sleep 3
echo "[+] coredns pending done"

echo "[i] enable hostpath provisioner"
if [ ! -e "/etc/kubernetes/manifests/kube-controller-manager.yaml" ]; then
  echo "File does not exist: /etc/kubernetes/manifests/kube-controller-manager.yaml" 1>&2
  exit 1
fi
sudo cat /etc/kubernetes/manifests/kube-controller-manager.yaml |
  yq -e '.spec.containers[].command += ["--enable-hostpath-provisioner=true"]' |
  sudo tee /etc/kubernetes/manifests/kube-controller-manager.yaml

# https://github.com/cilium/cilium
# https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
echo "[i] install cilium helm"
CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium/master/stable.txt)
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
  --version ${CILIUM_VERSION} \
  --namespace kube-system \
  --set operator.replicas=1

echo "[i] install cilium cli"
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -s -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

cilium status --wait

echo "[i] taint node"
kubectl taint node --all node-role.kubernetes.io/control-plane:NoSchedule-

echo "[i] node info"
kubectl get nodes -o wide

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
