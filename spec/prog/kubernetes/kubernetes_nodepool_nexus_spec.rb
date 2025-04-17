# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodepoolNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:project) { Project.create(name: "default") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }

  let(:kc) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2"
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)
    kc.update(api_server_lb_id: lb.id)
    kc
  }

  let(:kn) { KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2") }

  before do
    allow(nx).to receive(:kubernetes_nodepool).and_return(kn)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(name: "name", node_count: 2, kubernetes_cluster_id: SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing cluster"

      expect {
        described_class.assemble(name: "name", node_count: 0, kubernetes_cluster_id: kc.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: worker_node_count"

      expect {
        described_class.assemble(name: "name", node_count: "2", kubernetes_cluster_id: kc.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: worker_node_count"
    end

    it "creates a kubernetes nodepool" do
      st = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: 37)
      kn = st.subject

      expect(kn.name).to eq "k8stest-np"
      expect(kn.ubid).to start_with("kn")
      expect(kn.kubernetes_cluster_id).to eq kc.id
      expect(kn.node_count).to eq 2
      expect(st.label).to eq "start"
      expect(kn.target_node_size).to eq "standard-4"
      expect(kn.target_node_storage_size_gib).to eq 37
    end

    it "can have null as storage size" do
      st = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: nil)

      expect(st.subject.target_node_storage_size_gib).to be_nil
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
    it "naps if the kubernetes cluster is not ready" do
      expect { nx.start }.to nap(10)
    end

    it "registers a deadline and hops if the cluster is ready" do
      expect(nx).to receive(:when_start_bootstrapping_set?).and_yield
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("create_services_load_balancer")
    end
  end

  describe "#create_services_load_balancer" do
    it "hops to bootstrap_worker_vms because lb already exists" do
      Prog::Vnet::LoadBalancerNexus.assemble(subnet.id, name: kc.services_load_balancer_name, src_port: 443, dst_port: 8443)
      expect { nx.create_services_load_balancer }.to hop("bootstrap_worker_vms")
    end

    it "creates the new services load balancer" do
      expect { nx.create_services_load_balancer }.to hop("bootstrap_worker_vms")
      expect(LoadBalancer[name: kc.services_load_balancer_name]).not_to be_nil
    end

    it "creates the new services load balancer with k8s DnsZone" do
      allow(Config).to receive(:kubernetes_service_hostname).and_return("k8s.ubicloud.com")
      dns_zone = DnsZone.create_with_id(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)

      expect { nx.create_services_load_balancer }.to hop("bootstrap_worker_vms")
      lb = LoadBalancer[name: kc.services_load_balancer_name]
      expect(lb).not_to be_nil
      expect(lb.name).to eq kc.services_load_balancer_name
      expect(lb.custom_hostname_dns_zone_id).to eq dns_zone.id
      expect(lb.custom_hostname).to eq "#{kc.ubid.to_s[-10...]}-services.k8s.ubicloud.com"
    end
  end

  describe "#bootstrap_worker_vms" do
    it "buds a total of node_count times ProvisionKubernetesNode prog to create VMs" do
      kn.node_count.times do
        expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kn.id, "subject_id" => kn.cluster.id})
      end
      expect { nx.bootstrap_worker_vms }.to hop("wait_worker_node")
    end
  end

  describe "#wait_worker_node" do
    before { expect(nx).to receive(:reap) }

    it "hops back to bootstrap_worker_vms if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_worker_node }.to hop("wait")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_worker_node }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    before { expect(nx).to receive(:reap) }

    it "donates if there are sub-programs running (Provision...)" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.destroy }.to nap(1)
    end

    it "destroys the nodepool and its vms" do
      Prog::Vnet::LoadBalancerNexus.assemble(subnet.id, name: kc.services_load_balancer_name, src_port: 443, dst_port: 8443)
      vms = [create_vm, create_vm]
      expect(kn).to receive(:vms).and_return(vms)

      expect(vms).to all(receive(:incr_destroy))
      expect(kn).to receive(:remove_all_vms)
      expect(kn).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end

    it "destroys the nodepool and its vms with non existing services loadbalancer" do
      vms = [create_vm, create_vm]
      expect(kn).to receive(:vms).and_return(vms)

      expect(vms).to all(receive(:incr_destroy))
      expect(kn).to receive(:remove_all_vms)
      expect(kn).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end
  end
end
