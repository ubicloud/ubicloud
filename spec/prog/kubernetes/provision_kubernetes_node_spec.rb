# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::ProvisionKubernetesNode do
  subject(:prog) { described_class.new(Strand.create(id: Strand.generate_uuid, prog: "Kubernetes::ProvisionKubernetesNode", label: "something")) }

  let(:kubernetes_cluster) {
    project = Project.create(name: "default")
    subnet = PrivateSubnet.create(net6: "0::0/16", net4: "127.0.0.0/8", name: "x", location: "x", project_id: project.id)
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", src_port: 123, dst_port: 456, health_check_endpoint: "/foo", project_id: project.id)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)

    kc.update(api_server_lb_id: lb.id)
    kc
  }

  let(:kubernetes_nodepool) { KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78) }

  before do
    allow(prog).to receive_messages(kubernetes_cluster: kubernetes_cluster, frame: {"vm_id" => create_vm.id})
  end

  describe "#before_run" do
    it "destroys itself and children if the kubernetes cluster is getting deleted" do
      Strand.create(id: kubernetes_cluster.id, label: "something", prog: "KubernetesClusterNexus")
      kubernetes_cluster.reload
      expect(kubernetes_cluster.strand.label).to eq("something")
      prog.before_run # Nothing happens

      kubernetes_cluster.strand.label = "destroy"
      2.times do |i|
        prog.strand.add_child(id: Strand.generate_uuid, prog: "something", label: "something")
      end
      expect(prog.strand.children.count).to eq(2)
      expect(prog.strand.children).to all(receive(:destroy))
      expect { prog.before_run }.to exit({"msg" => "provisioning canceled"})

      prog.strand.label = "destroy"
      prog.before_run # Nothing happens
    end
  end

  describe "#write_hosts_file_if_needed" do
    it "exits early if the environment is not dev" do
      expect(prog.vm).not_to receive(:sshable)
      expect(Config).to receive(:development?).and_return(false)
      prog.write_hosts_file_if_needed
    end

    it "exits early if /etc/hosts file contains an entry about the cluster endpoint already" do
      sshable = instance_double(Sshable)
      allow(prog.vm).to receive(:sshable).and_return(sshable)
      expect(Config).to receive(:development?).and_return(true)

      expect(sshable).to receive(:cmd).with("cat /etc/hosts").and_return("something #{kubernetes_cluster.endpoint} something")
      expect(sshable).not_to receive(:cmd).with(/echo/)
      prog.write_hosts_file_if_needed
    end

    it "creates an /etc/hosts entry linking the cluster endpoint to the IP4 of the first VM" do
      sshable = instance_double(Sshable)
      allow(prog.vm).to receive(:sshable).and_return(sshable)
      expect(Config).to receive(:development?).and_return(true)

      expect(sshable).to receive(:cmd).with("cat /etc/hosts").and_return("nothing relevant")
      expect(kubernetes_cluster).to receive(:sshable).and_return(instance_double(Sshable, host: "SOMEIP"))
      expect(sshable).to receive(:cmd).with("sudo tee -a /etc/hosts", {stdin: /SOMEIP somelb\..*\n/})

      prog.write_hosts_file_if_needed
    end

    it "uses the given IP an /etc/hosts entry linking the cluster endpoint to the IP4 of the first VM" do
      sshable = instance_double(Sshable)
      expect(prog.vm).to receive(:sshable).and_return(sshable).twice
      expect(Config).to receive(:development?).and_return(true)

      expect(sshable).to receive(:cmd).with("cat /etc/hosts").and_return("nothing relevant")
      expect(kubernetes_cluster).not_to receive(:sshable)
      expect(sshable).to receive(:cmd).with("sudo tee -a /etc/hosts", {stdin: /ANOTHERIP somelb\..*\n/})

      prog.write_hosts_file_if_needed "ANOTHERIP"
    end
  end

  describe "#start" do
    it "creates a CP VM and hops if a nodepool is not given" do
      expect(prog.kubernetes_nodepool).to be_nil
      expect(kubernetes_cluster.cp_vms.count).to eq(2)
      expect(kubernetes_cluster.api_server_lb).to receive(:add_vm)

      expect { prog.start }.to hop("install_software")

      expect(kubernetes_cluster.cp_vms.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms.last
      expect(new_vm.name).to start_with("k8scluster-control-plane-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(4)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(37)
    end

    it "creates a worker VM and hops if a nodepool is given" do
      expect(prog).to receive(:frame).and_return({"nodepool_id" => kubernetes_nodepool.id})
      expect(kubernetes_nodepool.vms.count).to eq(0)

      expect { prog.start }.to hop("install_software")

      expect(kubernetes_nodepool.reload.vms.count).to eq(1)

      new_vm = kubernetes_nodepool.vms.last
      expect(new_vm.name).to start_with("k8stest-np-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.vcpus).to eq(8)
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq(78)
    end

    it "assigns the default storage size if not specified" do
      kubernetes_cluster.update(target_node_storage_size_gib: nil)
      expect(kubernetes_cluster.api_server_lb).to receive(:add_vm)

      expect(kubernetes_cluster.cp_vms.count).to eq(2)

      expect { prog.start }.to hop("install_software")

      expect(kubernetes_cluster.cp_vms.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms.last
      expect(new_vm.strand.stack.first["storage_volumes"].first["size_gib"]).to eq 80
    end
  end

  describe "#install_software" do
    it "waits until the VM is ready" do
      st = instance_double(Strand, label: "non-wait")
      expect(prog.vm).to receive(:strand).and_return(st)
      expect { prog.install_software }.to nap(5)
    end

    it "runs a bunch of commands to install kubernetes if the VM is ready, then hops" do
      st = instance_double(Strand, label: "wait")
      sshable = instance_double(Sshable)
      expect(prog.vm).to receive(:strand).and_return(st)
      expect(prog.vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with(/sudo apt install -y kubelet kubeadm kubectl/)
      expect { prog.install_software }.to hop("apply_nat_rules")
    end
  end

  describe "#apply_nat_rules" do
    it "applies nat rules and hops to rhizome installation" do
      sshable = instance_double(Sshable)
      expect(prog.vm).to receive_messages(sshable: sshable, nics: [instance_double(Nic, private_ipv4: "10.10.20.30/26")])
      expect(sshable).to receive(:cmd).with("sudo iptables-nft -t nat -A POSTROUTING -s 10.10.20.30/26 -o ens3 -j MASQUERADE")
      expect { prog.apply_nat_rules }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(prog).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => prog.vm.id, "user" => "ubi"})
      expect { prog.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(prog).to receive(:reap) }

    it "hops to assign_role if there are no sub-programs running" do
      expect(prog).to receive(:leaf?).and_return true

      expect { prog.wait_bootstrap_rhizome }.to hop("assign_role")
    end

    it "donates if there are sub-programs running" do
      expect(prog).to receive(:leaf?).and_return false
      expect(prog).to receive(:donate).and_call_original

      expect { prog.wait_bootstrap_rhizome }.to nap(1)
    end
  end

  describe "#assign_role" do
    it "hops to init_cluster if this is the first vm of the cluster" do
      expect(prog).to receive(:write_hosts_file_if_needed)
      expect(prog.kubernetes_cluster.cp_vms).to receive(:count).and_return(1)
      expect { prog.assign_role }.to hop("init_cluster")
    end

    it "hops to join_control_plane if this is the not the first vm of the cluster" do
      expect(prog.kubernetes_cluster.cp_vms.count).to eq(2)
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
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("NotStarted")
      expect(prog.vm).to receive(:nics).and_return([instance_double(Nic, private_ipv4: "10.0.0.37")])
      expect(prog.vm.sshable).to receive(:cmd).with(
        "common/bin/daemonizer /home/ubi/kubernetes/bin/init-cluster init_kubernetes_cluster",
        stdin: /{"cluster_name":"k8scluster","lb_hostname":"somelb\..*","port":"443","private_subnet_cidr4":"127.0.0.0\/8","private_subnet_cidr6":"::\/16","vm_cidr":"10.0.0.37"}/
      )

      expect { prog.init_cluster }.to nap(30)
    end

    it "naps if the init_cluster script is in progress" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("InProgress")
      expect { prog.init_cluster }.to nap(10)
    end

    it "naps and does nothing (for now) if the init_cluster script is failed" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("Failed")
      expect { prog.init_cluster }.to nap(65536)
    end

    it "pops if the init_cluster script is successful" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("Succeeded")
      expect { prog.init_cluster }.to hop("install_cni")
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("Unknown")
      expect { prog.init_cluster }.to nap(65536)
    end
  end

  describe "#join_control_plane" do
    before { allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable)) }

    it "runs the join_control_plane script if it's not started" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("NotStarted")

      sshable = instance_double(Sshable)
      allow(kubernetes_cluster.cp_vms.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).and_return("jt\n")
      expect(sshable).to receive(:cmd).with("sudo kubeadm init phase upload-certs --upload-certs", log: false).and_return("something\ncertificate key:\nck")
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --print-join-command", log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:cmd).with(
        "common/bin/daemonizer kubernetes/bin/join-control-plane-node join_control_plane",
        stdin: /{"cluster_endpoint":"somelb\..*:443","join_token":"jt","certificate_key":"ck","discovery_token_ca_cert_hash":"dtcch"}/,
        log: false
      )

      expect { prog.join_control_plane }.to nap(15)
    end

    it "naps if the join_control_plane script is in progress" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("InProgress")
      expect { prog.join_control_plane }.to nap(10)
    end

    it "naps and does nothing (for now) if the join_control_plane script is failed" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("Failed")
      expect { prog.join_control_plane }.to nap(65536)
    end

    it "pops if the join_control_plane script is successful" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("Succeeded")
      expect { prog.join_control_plane }.to hop("install_cni")
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("Unknown")
      expect { prog.join_control_plane }.to nap(65536)
    end
  end

  describe "#join_worker" do
    before {
      allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable))
      allow(prog).to receive(:kubernetes_nodepool).and_return(kubernetes_nodepool)
    }

    it "runs the join-worker-node script if it's not started" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_worker").and_return("NotStarted")

      sshable = instance_double(Sshable)
      allow(kubernetes_cluster.cp_vms.first).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).and_return("\njt\n")
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --print-join-command", log: false).and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:cmd).with(
        "common/bin/daemonizer kubernetes/bin/join-worker-node join_worker",
        stdin: /{"endpoint":"somelb\..*:443","join_token":"jt","discovery_token_ca_cert_hash":"dtcch"}/,
        log: false
      )

      expect { prog.join_worker }.to nap(15)
    end

    it "naps if the join-worker-node script is in progress" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_worker").and_return("InProgress")
      expect { prog.join_worker }.to nap(10)
    end

    it "naps and does nothing (for now) if the join-worker-node script is failed" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_worker").and_return("Failed")
      expect { prog.join_worker }.to nap(65536)
    end

    it "pops if the join-worker-node script is successful" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_worker").and_return("Succeeded")
      expect { prog.join_worker }.to hop("install_cni")
    end

    it "naps for a long time if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_worker").and_return("Unknown")
      expect { prog.join_worker }.to nap(65536)
    end
  end

  describe "#install_cni" do
    it "configures ubicni" do
      sshable = instance_double(Sshable)
      allow(prog.vm).to receive_messages(
        sshable: sshable,
        nics: [instance_double(Nic, private_ipv4: "10.0.0.37", private_ipv6: "0::1")],
        ephemeral_net6: NetAddr::IPv6Net.new(NetAddr::IPv6.parse("2001:db8::"), NetAddr::Mask128.new(64))
      )

      expect(sshable).to receive(:cmd).with("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: /"type": "ubicni"/)
      expect { prog.install_cni }.to exit({vm_id: prog.vm.id})
    end
  end
end
