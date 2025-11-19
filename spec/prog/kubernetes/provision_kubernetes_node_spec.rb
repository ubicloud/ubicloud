# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::ProvisionKubernetesNode do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Kubernetes::ProvisionKubernetesNode", label: "start") }

  let(:project) {
    Project.create(name: "default")
  }
  let(:subnet) {
    Prog::Vnet::SubnetNexus.assemble(Config.kubernetes_service_project_id, name: "test", ipv4_range: "172.19.0.0/16", ipv6_range: "fd40:1a0a:8d48:182a::/64").subject
  }

  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37
    )
    Firewall.create(name: "#{kc.ubid}-cp-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
    Firewall.create(name: "#{kc.ubid}-worker-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    KubernetesNode.create(vm_id: create_vm(created_at: Time.now - 1).id, kubernetes_cluster_id: kc.id)
    kc.update(api_server_lb_id: lb.id)
  }

  let(:node) {
    nic = Prog::Vnet::NicNexus.assemble(subnet.id, ipv4_addr: "172.19.145.64/26", ipv6_addr: "fd40:1a0a:8d48:182a::/79").subject
    vm = Prog::Vm::Nexus.assemble("pub key", Config.kubernetes_service_project_id, name: "test-vm", private_subnet_id: subnet.id, nic_id: nic.id).subject
    vm.update(ephemeral_net6: "2001:db8:85a3:73f2:1c4a::/79", created_at: Time.now - 1)
    KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kubernetes_cluster.id)
  }

  let(:kubernetes_nodepool) { KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78) }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(prog).to receive_messages(kubernetes_cluster: kubernetes_cluster, frame: {"node_id" => node.id})
  end

  describe "random_ula_cidr" do
    it "returns a /108 subnet" do
      cidr = prog.random_ula_cidr
      expect(cidr.netmask.prefix_len).to eq(108)
    end

    it "returns an address in the fd00::/8 range" do
      cidr = prog.random_ula_cidr
      ula_range = NetAddr::IPv6Net.parse("fd00::/8")
      expect(ula_range.cmp(cidr)).to be(-1)
    end
  end

  describe "node" do
    it "finds the right node" do
      node = KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kubernetes_cluster.id)
      expect(prog).to receive(:frame).and_return({"node_id" => node.id})
      expect(prog.node.id).to eq(node.id)
    end
  end

  describe "#before_run" do
    it "destroys itself if the kubernetes cluster is getting deleted" do
      Strand.create(id: kubernetes_cluster.id, label: "something", prog: "KubernetesClusterNexus")
      kubernetes_cluster.reload
      expect(kubernetes_cluster.strand.label).to eq("something")
      prog.before_run # Nothing happens

      kubernetes_cluster.strand.label = "destroy"
      expect { prog.before_run }.to exit({"msg" => "provisioning canceled"})

      prog.strand.label = "destroy"
      prog.before_run # Nothing happens
    end
  end

  describe "#start" do
    it "creates a control plane node and hops if a nodepool is not given" do
      expect(prog.kubernetes_nodepool).to be_nil
      expect(kubernetes_cluster.nodes.count).to eq(2)

      expect { prog.start }.to hop("bootstrap_rhizome")
      kubernetes_cluster.reload

      expect(kubernetes_cluster.nodes.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms.last
      expect(new_vm.name).to start_with("#{kubernetes_cluster.ubid}-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(4)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(37)
      expect(new_vm.boot_image).to eq("kubernetes-#{Option.kubernetes_versions.first.tr(".", "_")}")
    end

    it "creates a worker node and hops if a nodepool is given" do
      expect(prog).to receive(:frame).and_return({"nodepool_id" => kubernetes_nodepool.id})
      expect(kubernetes_nodepool.nodes.count).to eq(0)

      expect { prog.start }.to hop("bootstrap_rhizome")

      expect(kubernetes_nodepool.reload.nodes.count).to eq(1)

      new_vm = kubernetes_nodepool.nodes.last.vm
      expect(new_vm.name).to start_with("#{kubernetes_nodepool.ubid}-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(8)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(78)
      expect(new_vm.boot_image).to eq("kubernetes-#{Option.kubernetes_versions.first.tr(".", "_")}")
    end

    it "assigns the default storage size if not specified" do
      kubernetes_cluster.update(target_node_storage_size_gib: nil)

      expect(kubernetes_cluster.nodes.count).to eq(2)

      expect { prog.start }.to hop("bootstrap_rhizome")
      kubernetes_cluster.reload

      expect(kubernetes_cluster.nodes.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms.last
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq 80
    end
  end

  describe "#bootstrap_rhizome" do
    it "waits until the node is ready" do
      st = instance_double(Strand, label: "non-wait")
      expect(prog.node.vm).to receive(:strand).and_return(st)
      expect { prog.bootstrap_rhizome }.to nap(5)
    end

    it "enables kubelet and buds a bootstrap rhizome process" do
      sshable = instance_double(Sshable)
      st = instance_double(Strand, label: "wait")
      expect(prog.node.vm).to receive(:strand).and_return(st)
      expect(prog.vm).to receive(:sshable).and_return(sshable).thrice
      expect(sshable).to receive(:cmd).with("sudo iptables-nft -t nat -A POSTROUTING -s 172.19.145.64/26 -o ens3 -j MASQUERADE")
      expect(sshable).to receive(:cmd).with(
        "sudo nft --file -",
        stdin: <<~TEMPLATE
table ip6 pod_access;
delete table ip6 pod_access;
table ip6 pod_access {
  chain ingress_egress_control {
    type filter hook forward priority filter; policy drop;
    # allow access to the vm itself in order to not break the normal functionality of Clover and SSH
    ip6 daddr 2001:db8:85a3:73f2:1c4a::2 ct state established,related,new counter accept
    ip6 saddr 2001:db8:85a3:73f2:1c4a::2 ct state established,related,new counter accept

    # not allow new connections from internet but allow new connections from inside
    ip6 daddr 2001:db8:85a3:73f2:1c4a::/79 ct state established,related counter accept
    ip6 saddr 2001:db8:85a3:73f2:1c4a::/79 ct state established,related,new counter accept

    # used for internal private ipv6 communication between pods
    ip6 saddr fd40:1a0a:8d48:182a::/64 ct state established,related,new counter accept
    ip6 daddr fd40:1a0a:8d48:182a::/64 ct state established,related,new counter accept
  }
}
        TEMPLATE
      )
      expect(sshable).to receive(:cmd).with("sudo systemctl enable --now kubelet")

      expect(prog).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => prog.node.vm.id, "user" => "ubi"})
      expect { prog.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to assign_role if there are no sub-programs running" do
      st.update(prog: "Kubernetes::ProvisionKubernetesNode", label: "wait_bootstrap_rhizome", stack: [{}])
      expect { prog.wait_bootstrap_rhizome }.to hop("assign_role")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::ProvisionKubernetesNode", label: "wait_bootstrap_rhizome", stack: [{}])
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { prog.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#assign_role" do
    it "hops to init_cluster if this is the first node of the cluster" do
      expect(prog.kubernetes_cluster.nodes).to receive(:count).and_return(1)
      expect { prog.assign_role }.to hop("init_cluster")
    end

    it "hops to join_control_plane if this is the not the first node of the cluster" do
      expect(prog.kubernetes_cluster.nodes.count).to eq(2)
      expect { prog.assign_role }.to hop("join_control_plane")
    end

    it "hops to join_worker if a nodepool is specified to the prog" do
      expect(prog).to receive(:kubernetes_nodepool).and_return(kubernetes_nodepool)
      expect { prog.assign_role }.to hop("join_worker")
    end
  end

  describe "#init_cluster" do
    before { allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable)) }

    it "runs the init_cluster script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("NotStarted")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "init_kubernetes_cluster", "/home/ubi/kubernetes/bin/init-cluster",
        stdin: /{"node_name":"test-vm","cluster_name":"k8scluster","lb_hostname":"somelb\..*","port":"443","private_subnet_cidr4":"172.19.0.0\/16","private_subnet_cidr6":"fd40:1a0a:8d48:182a::\/64","node_ipv4":"172.19.145.65","node_ipv6":"2001:db8:85a3:73f2:1c4a::2"/, log: false
      )

      expect { prog.init_cluster }.to nap(30)
    end

    it "naps if the init_cluster script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("InProgress")
      expect { prog.init_cluster }.to nap(10)
    end

    it "naps and does nothing (for now) if the init_cluster script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Failed")
      expect { prog.init_cluster }.to nap(65536)
    end

    it "pops if the init_cluster script is successful" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Succeeded")
      expect { prog.init_cluster }.to hop("install_cni")
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("init_kubernetes_cluster").and_return("Unknown")
      expect { prog.init_cluster }.to nap(65536)
    end
  end

  describe "#join_control_plane" do
    before { allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable)) }

    it "runs the join_control_plane script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("NotStarted")

      sshable = instance_double(Sshable)
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).and_return("jt\n")
      expect(sshable).to receive(:cmd).with("sudo kubeadm init phase upload-certs --upload-certs", log: false).and_return("something\ncertificate key:\nck")
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --print-join-command", log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "join_control_plane", "kubernetes/bin/join-node",
        stdin: /{"is_control_plane":true,"node_name":"test-vm","endpoint":"somelb\..*:443","join_token":"jt","certificate_key":"ck","discovery_token_ca_cert_hash":"dtcch","node_ipv4":"172.19.145.65","node_ipv6":"2001:db8:85a3:73f2:1c4a::2"}/,
        log: false
      )

      expect { prog.join_control_plane }.to nap(15)
    end

    it "naps if the join_control_plane script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("InProgress")
      expect { prog.join_control_plane }.to nap(10)
    end

    it "naps and does nothing (for now) if the join_control_plane script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Failed")
      expect { prog.join_control_plane }.to nap(65536)
    end

    it "pops if the join_control_plane script is successful" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Succeeded")
      expect { prog.join_control_plane }.to hop("install_cni")
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_control_plane").and_return("Unknown")
      expect { prog.join_control_plane }.to nap(65536)
    end
  end

  describe "#join_worker" do
    before {
      allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable))
      allow(prog).to receive(:kubernetes_nodepool).and_return(kubernetes_nodepool)
    }

    it "runs the join-worker-node script if it's not started" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("NotStarted")

      sshable = instance_double(Sshable)
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).and_return("\njt\n")
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --print-join-command", log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:d_run).with(
        "join_worker", "kubernetes/bin/join-node",
        stdin: /{"is_control_plane":false,"node_name":"test-vm","endpoint":"somelb\..*:443","join_token":"jt","discovery_token_ca_cert_hash":"dtcch","node_ipv4":"172.19.145.65","node_ipv6":"2001:db8:85a3:73f2:1c4a::2"}/,
        log: false
      )

      expect { prog.join_worker }.to nap(15)
    end

    it "naps if the join-worker-node script is in progress" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("InProgress")
      expect { prog.join_worker }.to nap(10)
    end

    it "naps and does nothing (for now) if the join-worker-node script is failed" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Failed")
      expect { prog.join_worker }.to nap(65536)
    end

    it "pops if the join-worker-node script is successful" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Succeeded")
      expect { prog.join_worker }.to hop("install_cni")
    end

    it "naps for a long time if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:d_check).with("join_worker").and_return("Unknown")
      expect { prog.join_worker }.to nap(65536)
    end
  end

  describe "#install_cni" do
    it "configures ubicni" do
      sshable = instance_double(Sshable)
      expect(prog.vm).to receive(:sshable).and_return(sshable)
      expect(prog.node.vm).to receive_messages(
        nics: [instance_double(Nic, private_ipv4: "10.0.0.37", private_ipv6: "0::1")],
        ephemeral_net6: NetAddr::IPv6Net.new(NetAddr::IPv6.parse("2001:db8::"), NetAddr::Mask128.new(64))
      )

      expect(sshable).to receive(:cmd).with("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: /"type": "ubicni"/)
      expect { prog.install_cni }.to hop("approve_new_csr")
    end
  end

  describe "#approve_new_csr" do
    it "approves the csr" do
      sshable = instance_double(Sshable)
      expect(kubernetes_cluster.functional_nodes.first).to receive(:sshable).and_return(sshable)
      expect(kubernetes_cluster).to receive(:incr_sync_internal_dns_config)
      expect(kubernetes_cluster).to receive(:incr_sync_worker_mesh)
      expect(sshable).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get csr | awk '/Pending/ && /kubelet-serving/ && /'\"#{node.name}\"'/ {print $1}' | xargs -r sudo kubectl --kubeconfig /etc/kubernetes/admin.conf certificate approve")
      expect { prog.approve_new_csr }.to exit({node_id: prog.node.id})
    end
  end
end
