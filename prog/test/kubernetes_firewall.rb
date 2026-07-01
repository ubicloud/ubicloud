# frozen_string_literal: true

class Prog::Test::KubernetesFirewall < Prog::Test::KubernetesBase
  frame_accessor :probe_vm_id, :probe_subnet_id

  def self.assemble
    super(cluster_name: "kubernetes-test-firewall", worker_node_count: 1)
  end

  label :start
  label :destroy_kubernetes
  label :finish
  label :failed

  label def wait_for_kubernetes_bootstrap
    hop_test_node_isolation if kubernetes_cluster.strand.label == "wait"
    nap 10
  end

  label def test_node_isolation
    # Provision a probe VM in a separate private subnet and confirm the
    # locked-down customer firewall keeps the cluster nodes unreachable from
    # outside the cluster's own subnet.
    subnet = Prog::Vnet::SubnetNexus.assemble(kubernetes_test_project_id, name: "#{cluster_name}-probe-subnet", location_id: Location::HETZNER_FSN1_ID).subject
    probe_vm = Prog::Vm::Nexus.assemble_with_sshable(kubernetes_test_project_id, sshable_unix_user: "ubi", name: "#{cluster_name}-probe", private_subnet_id: subnet.id, boot_image: "ubuntu-noble", enable_ip4: true).subject

    self.probe_subnet_id = subnet.id
    self.probe_vm_id = probe_vm.id
    hop_wait_probe_vm
  end

  label def wait_probe_vm
    nap 10 unless probe_vm.strand.label == "wait"
    probe_vm.sshable.cmd("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
    hop_verify_node_isolation
  end

  label def verify_node_isolation
    reachable_node = kubernetes_cluster.all_nodes.find { node_port_reachable?(it, 10250) }
    if reachable_node
      self.fail_message = "node #{reachable_node.name} is reachable on port 10250 from a foreign subnet despite the locked-down customer firewall"
    end
    hop_teardown_probe
  end

  label def teardown_probe
    probe_vm.incr_destroy
    probe_subnet.firewalls.each(&:destroy)
    probe_subnet.incr_destroy
    hop_wait_probe_teardown
  end

  label def wait_probe_teardown
    nap 5 if probe_vm || probe_subnet
    hop_destroy_kubernetes
  end

  def probe_vm
    @probe_vm ||= Vm[probe_vm_id]
  end

  def probe_subnet
    @probe_subnet ||= PrivateSubnet[probe_subnet_id]
  end

  def node_port_reachable?(node, port)
    {"-4" => node.vm.ip4_string, "-6" => node.vm.ip6_string}.any? { |family, ip| tcp_reachable?(ip, port, family) }
  end

  def tcp_reachable?(ip, port, family)
    probe_vm.sshable.cmd("nc -zvw 5 :family :ip :port", family:, ip:, port: port.to_s)
    true
  rescue Sshable::SshError
    false
  end
end
