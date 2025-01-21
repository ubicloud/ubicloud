# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::ProvisionKubernetesNode do
  subject(:prog) { described_class.new(Strand.new) }

  let(:kubernetes_cluster) {
    project = Project.create_with_id(name: "default")
    subnet = PrivateSubnet.create_with_id(net6: "0::0/16", net4: "127.0.0.0/8", name: "x", location: "x", project_id: Config.kubernetes_service_project_id)
    kc = KubernetesCluster.create_with_id(
      name: "k8scluster",
      kubernetes_version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id
    )

    lb = LoadBalancer.create_with_id(private_subnet_id: subnet.id, name: "somelb", src_port: 123, dst_port: 456, health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)

    kc.update(api_server_lb_id: lb.id)
    kc
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(prog).to receive_messages(kubernetes_cluster: kubernetes_cluster, frame: {"vm_id" => create_vm.id})
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

      expect(sshable).to receive(:cmd).with("sudo cat /etc/hosts").and_return("something #{kubernetes_cluster.endpoint} something")
      expect(sshable).not_to receive(:cmd).with(/echo/)
      prog.write_hosts_file_if_needed
    end

    it "creates an /etc/hosts entry linking the cluster endpoint to the IP4 of the first VM" do
      sshable = instance_double(Sshable)
      allow(prog.vm).to receive(:sshable).and_return(sshable)
      expect(Config).to receive(:development?).and_return(true)

      expect(sshable).to receive(:cmd).with("sudo cat /etc/hosts").and_return("nothing relevant")
      expect(kubernetes_cluster.cp_vms.first).to receive(:ephemeral_net4).and_return("SOMEIP")
      expect(sshable).to receive(:cmd).with(/echo 'SOMEIP somelb.*' \| sudo tee -a \/etc\/hosts/)

      prog.write_hosts_file_if_needed
    end

    it "uses the given IP an /etc/hosts entry linking the cluster endpoint to the IP4 of the first VM" do
      sshable = instance_double(Sshable)
      expect(prog.vm).to receive(:sshable).and_return(sshable).twice
      expect(Config).to receive(:development?).and_return(true)

      expect(sshable).to receive(:cmd).with("sudo cat /etc/hosts").and_return("nothing relevant")
      expect(kubernetes_cluster.cp_vms.first).not_to receive(:ephemeral_net4)
      expect(sshable).to receive(:cmd).with(/echo 'ANOTHERIP somelb.*' \| sudo tee -a \/etc\/hosts/)

      prog.write_hosts_file_if_needed "ANOTHERIP"
    end
  end

  describe "#start" do
    it "creates a VM and hops" do
      expect(kubernetes_cluster.cp_vms.count).to eq(2)
      expect(kubernetes_cluster.api_server_lb).to receive(:add_vm)

      expect { prog.start }.to hop("install_software")

      expect(kubernetes_cluster.cp_vms.count).to eq(3)

      new_vm = kubernetes_cluster.cp_vms.last
      expect(new_vm.name).to start_with("k8scluster-control-plane-")
      expect(new_vm.sshable).not_to be_nil
      expect(new_vm.project_id).to eq(Config.kubernetes_service_project_id)
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
      expect { prog.install_software }.to hop("bootstrap_rhizome")
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
  end

  describe "#init_cluster" do
    before { allow(prog.vm).to receive(:sshable).and_return(instance_double(Sshable)) }

    it "runs the init_cluster script if it's not started" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_kubernetes_cluster").and_return("NotStarted")
      expect(prog.vm).to receive(:nics).and_return([instance_double(Nic, private_ipv4: "10.0.0.37")])
      expect(prog.vm.sshable).to receive(:cmd).with(/.*daemonizer '.*init-cluster k8scluster somelb.* 443 127.0.0.0\/8 ::\/16 10.0.0.37' init_kubernetes_cluster/)

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
      expect { prog.init_cluster }.to exit({vm_id: prog.vm.id})
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
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --ttl 24h --usages signing,authentication").and_return("\njt\n")
      expect(sshable).to receive(:cmd).with("sudo kubeadm init phase upload-certs --upload-certs").and_return("something\ncertificate key:\nck")
      expect(sshable).to receive(:cmd).with("sudo kubeadm token create --print-join-command").and_return("discovery-token-ca-cert-hash dtcch")
      expect(prog.vm.sshable).to receive(:cmd).with(/.*daemonizer '.*join-control-plane-node somelb.*:443 jt dtcch ck' join_control_plane/)

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
      expect { prog.join_control_plane }.to exit({vm_id: prog.vm.id})
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(prog.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check join_control_plane").and_return("Unknown")
      expect { prog.join_control_plane }.to nap(65536)
    end
  end
end
