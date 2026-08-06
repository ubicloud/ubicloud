# frozen_string_literal: true

require_relative "../../common/lib/util"

class KubernetesBuildNodeImage
  VERSION_PATTERN = /\Av\d+\.\d+\z/
  KEYRING = "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
  KEY_PATH = "/tmp/kubernetes-release.key"

  SYSCTL_CONF = <<~CONF
    net.ipv6.conf.all.forwarding=1
    net.ipv6.conf.all.proxy_ndp=1
    net.ipv4.conf.all.forwarding=1
    net.ipv4.ip_forward=1
  CONF

  def initialize(argv)
    fail "expected a single argument, a kubernetes version like v1.35, got #{argv.length}" unless argv.length == 1
    fail "expected a kubernetes version like v1.35, got #{argv[0].inspect}" unless VERSION_PATTERN.match?(argv[0])

    @kubernetes_version = argv[0]
  end

  def repo_url
    "https://pkgs.k8s.io/core:/stable:/#{@kubernetes_version}/deb/"
  end

  def run
    ENV["DEBIAN_FRONTEND"] = "noninteractive"

    r "sudo tee /etc/sysctl.d/72-clover-forward-packets.conf > /dev/null", stdin: SYSCTL_CONF

    r "sudo -E apt-get update"
    r "sudo -E apt-get upgrade -y"
    r "sudo -E apt-get install -y ca-certificates curl gpg"

    r "sudo install -m 0755 -d /etc/apt/keyrings"
    r "curl -fsSL :url -o :path", url: "#{repo_url}Release.key", path: KEY_PATH
    r "sudo gpg --batch --yes --dearmor -o :keyring :path", keyring: KEYRING, path: KEY_PATH
    r "rm -f :path", path: KEY_PATH
    r "echo :line | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null", line: "deb [signed-by=#{KEYRING}] #{repo_url} /"

    r "sudo -E apt-get update"
    r "sudo -E apt-get install -y containerd cri-tools kubelet kubeadm kubectl ruby-bundler"

    r "sudo mkdir -p /etc/containerd"
    r "sudo tee /etc/containerd/config.toml > /dev/null", stdin: r("containerd config default").gsub("SystemdCgroup = false", "SystemdCgroup = true")

    r "kubernetes/bin/install-node-exporter"
    r "kubernetes/bin/install-prometheus"

    r "sudo apt-mark hold kubelet kubeadm kubectl"
    r "sudo systemctl disable unattended-upgrades"

    r "sudo -E apt-get autoremove -y"
    r "sudo -E apt-get clean"
    r "sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*"
  end
end
