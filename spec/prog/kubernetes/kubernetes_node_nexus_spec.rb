# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodeNexus do
  subject(:st) { Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77") }

  let(:nx) { described_class.new(st) }
  let(:project) { Project.create(name: "default") }
  let(:subnet) { Prog::Vnet::SubnetNexus.assemble(Config.kubernetes_service_project_id, name: "test", ipv4_range: "172.19.0.0/16", ipv6_range: "fd40:1a0a:8d48:182a::/64").subject }
  let(:kc) {
    kc = KubernetesCluster.create(
      name: "cluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2"
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "lb", health_check_endpoint: "/", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.update(api_server_lb_id: lb.id)
    kc
  }
  let(:kd) { described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(nx).to receive(:kubernetes_node).and_return(kd)
  end

  describe ".assemble" do
    it "creates a kubernetes node" do
      st = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil)
      kd = st.subject

      expect(kd.vm.name).to eq "vm2"
      expect(kd.ubid).to start_with("kd")
      expect(kd.kubernetes_cluster_id).to eq kc.id
      expect(st.label).to eq "start"
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "hops to wait" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to retire when semaphore is set" do
      expect(nx).to receive(:when_retire_set?).and_yield
      expect { nx.wait }.to hop("retire")
    end
  end

  describe "#retire" do
    let(:sshable) { instance_double(Sshable) }
    let(:unit_name) { "drain_node_#{kd.name}" }

    before do
      expect(kd.kubernetes_cluster).to receive(:sshable).and_return(sshable).at_least(:once)
    end

    it "starts the drain process when run for the first time and naps" do
      expect(sshable).to receive(:d_check).with(unit_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(unit_name, "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "drain", kd.name, "--ignore-daemonsets", "--delete-emptydir-data")
      expect { nx.retire }.to nap(10)
    end

    it "naps when the node is getting drained" do
      expect(sshable).to receive(:d_check).with(unit_name).and_return("InProgress")
      expect { nx.retire }.to nap(10)
    end

    it "restarts when it fails" do
      expect(sshable).to receive(:d_check).with(unit_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(unit_name)
      expect { nx.retire }.to nap(10)
    end

    it "naps when daemonizer something unexpected and waits for the page" do
      expect(sshable).to receive(:d_check).with(unit_name).and_return("UnexpectedState")
      expect(nx).to receive(:register_deadline).with("destroy", 0)
      expect { nx.retire }.to nap(60 * 60 * 24)
    end

    it "drains the old node and hops to drop the old node" do
      expect(sshable).to receive(:d_check).with(unit_name).and_return("Succeeded")
      expect { nx.retire }.to hop("remove_node_from_cluster")
    end
  end

  describe "#remove_node_from_cluster" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kd.kubernetes_cluster).to receive(:client).and_return(client)
    end

    it "deletes the node and does nothing else if node doesn't belong to a KubernetesNodepool" do
      expect(client).to receive(:delete_node).with(kd.name)
      expect { nx.remove_node_from_cluster }.to hop("destroy")
    end

    it "deletes the node and deletes the node from its KubernetesNodepool's vms" do
      kn = KubernetesNodepool.create(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      kd.update(kubernetes_nodepool_id: kn.id)

      expect(client).to receive(:delete_node).with(kd.name)
      expect { nx.remove_node_from_cluster }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "destroys the vm and itself" do
      expect(kd.vm).to receive(:incr_destroy)
      expect(kd).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "kubernetes node is deleted"})
    end
  end
end
