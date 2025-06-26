# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodepoolNexus do
  subject(:st) { Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77") }

  let(:nx) { described_class.new(st) }
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

      record = DnsRecord[name: "*.#{kc.ubid.to_s[-10...]}-services.k8s.ubicloud.com."]
      expect(record).not_to be_nil
      expect(record.type).to eq "CNAME"
      expect(record.data).to eq "#{lb.hostname}."
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
    it "hops back to bootstrap_worker_vms if there are no sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesNodepoolNexus", label: "wait_worker_node", stack: [{}])
      expect { nx.wait_worker_node }.to hop("wait")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesNodepoolNexus", label: "wait_worker_node", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_worker_node }.to nap(120)
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to upgrade when semaphore is set" do
      expect(nx).to receive(:when_upgrade_set?).and_yield
      expect { nx.wait }.to hop("upgrade")
    end
  end

  describe "#upgrade" do
    let(:first_vm) { create_vm }
    let(:second_vm) { create_vm }
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      sshable0, sshable1 = instance_double(Sshable), instance_double(Sshable)
      expect(kn).to receive(:vms).and_return([first_vm, second_vm])
      allow(first_vm).to receive(:sshable).and_return(sshable0)
      allow(second_vm).to receive(:sshable).and_return(sshable1)
      allow(sshable0).to receive(:connect)
      allow(sshable1).to receive(:connect)

      expect(kn.cluster).to receive(:client).and_return(client).at_least(:once)
    end

    it "selects a VM with minor version one less than the cluster's version" do
      expect(kn.cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.32", "v1.31")
      expect(nx).to receive(:bud).with(Prog::Kubernetes::UpgradeKubernetesNode, {"nodepool_id" => kn.id, "old_vm_id" => second_vm.id, "subject_id" => kn.cluster.id})
      expect { nx.upgrade }.to hop("wait_upgrade")
    end

    it "hops to wait when all VMs are at the cluster's version" do
      expect(kn.cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.32", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "does not select a VM with minor version more than one less than the cluster's version" do
      expect(kn.cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.30", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "skips VMs with invalid version formats" do
      expect(kn.cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("invalid", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "selects the first VM that is one minor version behind" do
      expect(kn.cluster).to receive(:version).and_return("v1.32")
      expect(client).to receive(:version).and_return("v1.31")
      expect(nx).to receive(:bud).with(Prog::Kubernetes::UpgradeKubernetesNode, {"nodepool_id" => kn.id, "old_vm_id" => first_vm.id, "subject_id" => kn.cluster.id})
      expect { nx.upgrade }.to hop("wait_upgrade")
    end

    it "hops to wait if cluster version is invalid" do
      expect(kn.cluster).to receive(:version).and_return("invalid").twice
      expect(client).to receive(:version).and_return("v1.31", "v1.31")
      expect { nx.upgrade }.to hop("wait")
    end

    it "does not select a VM with a higher minor version than the cluster" do
      expect(kn.cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.33", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end
  end

  describe "#wait_upgrade" do
    it "hops back to upgrade if there are no sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesNodepoolNexus", label: "wait_upgrade", stack: [{}])
      expect { nx.wait_upgrade }.to hop("upgrade")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesNodepoolNexus", label: "wait_upgrade", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::UpgradeKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_upgrade }.to nap(120)
    end
  end

  describe "#destroy" do
    it "donates if there are sub-programs running (Provision...)" do
      st.update(prog: "Kubernetes::KubernetesNodepoolNexus", label: "wait_upgrade", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::UpgradeKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.destroy }.to nap(120)
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

    it "deletes the sub-subdomain DNS record if the DNS zone exists" do
      dns_zone = DnsZone.create_with_id(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)
      Prog::Vnet::LoadBalancerNexus.assemble(
        subnet.id,
        name: kc.services_load_balancer_name,
        custom_hostname_dns_zone_id: dns_zone&.id,
        custom_hostname_prefix: "#{kc.ubid.to_s[-10...]}-services",
        src_port: 443, dst_port: 8443
      )

      dns_zone.insert_record(record_name: "*.#{kc.ubid.to_s[-10...]}-services.k8s.ubicloud.com.", type: "CNAME", ttl: 123, data: "whatever.")

      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
      expect(DnsRecord[name: "*.#{kc.ubid.to_s[-10...]}-services.k8s.ubicloud.com.", tombstoned: true]).not_to be_nil
    end

    it "completes the destroy process even if the load balancer does not exist" do
      expect(LoadBalancer[name: kc.services_load_balancer_name]).to be_nil
      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end

    it "completes the destroy process even if the DNS zone does not exist" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(
        subnet.id,
        name: kc.services_load_balancer_name,
        src_port: 443, dst_port: 8443
      ).subject

      expect(LoadBalancer).to receive(:[]).and_return(lb)
      expect(lb).to receive(:incr_destroy)
      expect(lb).to receive(:dns_zone).and_return(nil)

      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end
  end
end
