#!/bin/sh

# Based on https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

K8S_VERSION=1.22.2
MASTER_IP=$1
POD_CIDR="192.168.0.0/16"
NODENAME=$(hostname)

#start installing system tools
apt update
apt upgrade
apt install -y curl apt-transport-https bash-completion binutils

curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list


swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

apt update
apt install -y docker.io containerd kubelet=${K8S_VERSION}-00 kubeadm=${K8S_VERSION}-00 kubectl=${K8S_VERSION}-00 kubernetes-cni

# Load required kernel modules
modprobe overlay
modprobe br_netfilter

#Load the kernel modules at every boot
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# Setting up sysctl
tee /etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

#Load the sysctl settings
sysctl --system

#containerd setup
mkdir -p /etc/containerd

### containerd config
cat > /etc/containerd/config.toml <<EOF
disabled_plugins = []
imports = []
oom_score = 0
plugin_dir = ""
required_plugins = []
root = "/var/lib/containerd"
state = "/run/containerd"
version = 2

[plugins]

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      base_runtime_spec = ""
      container_annotations = []
      pod_annotations = []
      privileged_without_host_devices = false
      runtime_engine = ""
      runtime_root = ""
      runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        BinaryName = ""
        CriuImagePath = ""
        CriuPath = ""
        CriuWorkPath = ""
        IoGid = 0
        IoUid = 0
        NoNewKeyring = false
        NoPivotRoot = false
        Root = ""
        ShimCgroup = ""
        SystemdCgroup = true
EOF


#setting crictl to use containerd
{
cat <<EOF | /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
}

#setting kubelet to use containerd
{
cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime remote --container-runtime-endpoint unix:///run/containerd/containerd.sock"
EOF
}

#starting up the services
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
systemctl enable kubelet --now

#cleaning up the previous system remnants if there was any
kubeadm reset -f
rm /root/.kube/config

#download the images locally so it will not "block" kubeadm init and it runs faster
kubeadm config images pull

#initializing k8s, setting it to specific version, not the latest one (default) and enable to run only with one cpu/core
kubeadm init --kubernetes-version=${K8S_VERSION} --ignore-preflight-errors=NumCPU 

mkdir -p ~/.kube
cp -i /etc/kubernetes/admin.conf ~/.kube/config

#initializing k8s, setting it to specific version, not the latest one (default) and enable to run only with one cpu/core
kubeadm init --kubernetes-version=${K8S_VERSION} --ignore-preflight-errors=NumCPU --apiserver-advertise-address=$MASTER_IP  --apiserver-cert-extra-sans=$MASTER_IP --pod-network-cidr=$POD_CIDR --node-name $NODENAME

kubeadm token create --print-join-command > join.sh
chmod +x join.sh

mkdir -p ~/.kube
cp -i /etc/kubernetes/admin.conf ~/.kube/config

curl https://docs.projectcalico.org/manifests/calico.yaml -O

kubectl apply -f calico.yaml
