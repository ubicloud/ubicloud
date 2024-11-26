####################################################
# CREATE CLUSTER
####################################################
master_st = Prog::Vm::Nexus.assemble_with_sshable(
  "ubi",
  Project.first.id,
  location: "hetzner-fsn1",
  name: "k8s-1-#{SecureRandom.alphanumeric(4).downcase}",
  size: "standard-2",
  storage_volumes: [
    {encrypted: true, size_gib: 30}
  ],
  boot_image: "ubuntu-jammy",
  enable_ip4: true
)

until master_st.reload.label == "wait" do sleep(1) end

other_sts = (2..3).map do |i|
  Prog::Vm::Nexus.assemble_with_sshable(
    "ubi",
    Project.first.id,
    location: "hetzner-fsn1",
    name: "k8s-#{i}-#{SecureRandom.alphanumeric(4).downcase}",
    size: "standard-2",
    storage_volumes: [
      {encrypted: true, size_gib: 30}
    ],
    boot_image: "ubuntu-jammy",
    enable_ip4: true,
    private_subnet_id: master_st.subject.private_subnets.first.id
  )
end

until other_sts.all? { |st| st.reload.label == "wait" } do sleep(1) end

####################################################
# Configure PRY vars
####################################################
vms = Vm.all.select { |vm| vm.name.start_with? "k8s" }.sort_by(&:name)
master = vms[0]
others = vms[1..]

####################################################
# SSH
####################################################
vms.each { |vm| vm.sshable.cmd("echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFO4CbIPZuNKWpoO5ZKqVnUdOQlUbzwHgyHiEscapeD6 eren@ubicloud.com' >> .ssh/authorized_keys") }

# MK
vms.each { |vm| vm.sshable.cmd("echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDrNHj134UB6vVwmAgRbo39Oq0Ny74SugfhpMqscVqjodDFW5/MMbcy8LNCNoK5jr7v1dUyZBNk3AsIolmnn1GELG4zk6ucYK922/rFkepSqsrYNRaDHgwZ2WxGeZ8CSlGrKDnI7KpMAsLMIUuiUblhOBwqLT0cZ5jOHBqLJB9fvUxRrEfDDsGuHT8AbqpXPH9HKL7rbCQGdBEOuQ57mBfInRl9rJLu3wmp4LOC+j/vGtJXlPWUJNpWiGEQZump0KFOeO/Hg/n2i+ZgOLjqUApX5FPgkCqPx88iFP7pEL8ehJAsb4pzDvHM7aj9stfbLPCeCXS15buJBJYO9UTASQTN mohammad@mohik' >> .ssh/authorized_keys") }

vms.map { |vm| [vm.name, "ssh #{vm.sshable.unix_user}@#{vm.sshable.host}"] }

# vms.map{|vm| vm.sshable.cmd "ip link"} # Visually check, should be fine

# vms.map{|vm| vm.sshable.cmd "sudo cat /sys/class/dmi/id/product_uuid"} # FAILS...

# vms.map{|vm| vm.sshable.cmd "sudo ufw allow 6443"}
# vms.map{|vm| vm.sshable.cmd "netstat -an"}
# vms.each{|vm| vm.sshable.cmd "sudo systemctl reboot"}
# vms.map{|vm| vm.sshable.cmd "nc 127.0.0.1 6443 -v"} # FAILS...
# vms.map{|vm| vm.sshable.cmd "sudo iptables -A INPUT -p tcp --dport 6443 -j ACCEPT"} # FAILS...

####################################################
# CONFIGURE NODES
####################################################
# Pre-req for containerd
vms.each { |vm| vm.sshable.cmd <<-SH }
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo modprobe br_netfilter
sudo modprobe overlay # already done, but just-in-case
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# Apply sysctl params without reboot
sudo sysctl --system
SH

vms.map { |vm| vm.sshable.cmd "sysctl net.ipv4.ip_forward" }

# Install containerd
vms.each { |vm| vm.sshable.cmd <<-SH }
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install containerd -y
sudo mkdir /etc/containerd
sudo touch /etc/containerd/config.toml
containerd config default | sudo tee /etc/containerd/config.toml
# sudo sed -i 's/systemd_cgroup = false/systemd_cgroup = true/' /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
SH

puts vms.map { |vm| vm.sshable.cmd "sudo systemctl status containerd" }

# Install k8s
vms.each { |vm| vm.sshable.cmd <<-SH }
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
SH

puts vms.map { |vm| vm.sshable.cmd "sudo apt list kubelet kubeadm kubectl containerd" }

vms.each { |vm| vm.sshable.cmd "sudo systemctl enable --now kubelet" }

####################################################
# Create K8S cluster
####################################################

# master.sshable.cmd("sudo kubeadm reset", stdin: "y") # in case...
# master.sshable.cmd "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 -v5" # flannel
# master.sshable.cmd "sudo kubeadm init --pod-network-cidr=192.168.0.0/16 -v5" # calico
master.sshable.cmd "sudo kubeadm init --pod-network-cidr=172.16.0.0/16 -v5" # calico (mk)

master.sshable.cmd <<-SH
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
SH

# # CALICO
# master.sshable.cmd <<-SH
# kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
# curl https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml -O
# kubectl create -f custom-resources.yaml
# SH

# CALICO v2
master.sshable.cmd <<-SH
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
SH

# Flannel
# master.sshable.cmd <<-SH
# wget https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
# # sed 's/vxlan/host-gw/' -i kube-flannel.yml
# SH
# master.sshable.cmd "cat kube-flannel.yml | grep host-gw"
# master.sshable.cmd "kubectl apply -f kube-flannel.yml"

# Wait for all posds to be in good shape
puts master.sshable.cmd "kubectl get pods --all-namespaces"

master.sshable.cmd <<-SH
kubectl -n kube-system  patch cm calico-config -p '{"data":{"veth_mtu":"1300"}}'
kubectl -n kube-system rollout restart ds calico-node
SH

# Join others
cmd = master.sshable.cmd "sudo kubeadm token create --print-join-command"
others.each { |vm| vm.sshable.cmd "sudo #{cmd}" }

puts master.sshable.cmd "kubectl get nodes"

####################################################
# EXAMPLE APPLICATION
####################################################
master.sshable.cmd <<-SH
sudo apt install unzip
wget https://github.com/kubernetes/examples/archive/refs/heads/master.zip
unzip master
mv examples-master examples
SH

# TODO: Rename service name to redis-slave
master.sshable.cmd <<-SH
kubectl create -f examples/guestbook-go/redis-master-controller.yaml
kubectl create -f examples/guestbook-go/redis-master-service.yaml
kubectl create -f examples/guestbook-go/redis-replica-controller.yaml
kubectl create -f examples/guestbook-go/redis-replica-service.yaml
kubectl create -f examples/guestbook-go/guestbook-controller.yaml
sed -i 's/LoadBalancer/NodePort/' examples/guestbook-go/guestbook-service.yaml
kubectl create -f examples/guestbook-go/guestbook-service.yaml
SH

puts master.sshable.cmd <<-SH
kubectl get pods -o wide
kubectl get services
SH

port = master.sshable.cmd "kubectl get service guestbook -o jsonpath='{.spec.ports[?(@.nodePort)].nodePort}'"
puts "http://#{others.first.sshable.host}:#{port}"

####################################################
# DESTROY
####################################################
master.private_subnets.first.incr_destroy
vms.each(&:incr_destroy)
