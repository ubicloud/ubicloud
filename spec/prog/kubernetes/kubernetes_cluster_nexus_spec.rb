# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesClusterNexus do
  subject(:nx) { described_class.new(Strand.new) }

  let(:project) { Project.create(name: "default") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location: "x", project_id: project.id) }

  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id,
      target_node_size: "standard-2"
    )
    KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", src_port: 123, dst_port: 456, health_check_endpoint: "/foo", project_id: project.id)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)
    kc.update(api_server_lb_id: lb.id)
  }

  before do
    allow(nx).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(project_id: SecureRandom.uuid, name: "k8stest", version: "v1.32", location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(version: "v1.30", project_id: project.id, name: "k8stest", location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Invalid Kubernetes Version"

      expect {
        described_class.assemble(name: "Uppercase", version: "v1.32", project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "hyph_en", version: "v1.32", project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "onetoolongnameforatestkubernetesclustername", version: "v1.32", project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      p = Project.create(name: "another")
      subnet.update(project_id: p.id)
      expect {
        described_class.assemble(name: "normalname", project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the given project"
    end

    it "creates a kubernetes cluster" do
      st = described_class.assemble(name: "k8stest", version: "v1.31", private_subnet_id: subnet.id, project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3, target_node_size: "standard-8", target_node_storage_size_gib: 100)

      kc = st.subject
      expect(kc.name).to eq "k8stest"
      expect(kc.ubid).to start_with("kc")
      expect(kc.version).to eq "v1.31"
      expect(kc.location).to eq "hetzner-fsn1"
      expect(kc.cp_node_count).to eq 3
      expect(kc.private_subnet.id).to eq subnet.id
      expect(kc.project.id).to eq project.id
      expect(kc.strand.label).to eq "start"
      expect(kc.target_node_size).to eq "standard-8"
      expect(kc.target_node_storage_size_gib).to eq 100
    end

    it "has defaults for node size, storage size, version and subnet" do
      st = described_class.assemble(name: "k8stest", project_id: project.id, location: "hetzner-fsn1", cp_node_count: 3)
      kc = st.subject

      expect(kc.version).to eq "v1.32"
      expect(kc.private_subnet.net4.to_s[-3..]).to eq "/18"
      expect(kc.private_subnet.name).to eq "k8stest-k8s-subnet"
      expect(kc.target_node_size).to eq "standard-2"
      expect(kc.target_node_storage_size_gib).to be_nil
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
    it "registers deadline and hops" do
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("create_load_balancer")
    end
  end

  describe "#create_load_balancer" do
    it "creates a load balancer with the right dns zone on prod for api server and hops" do
      allow(Config).to receive(:kubernetes_service_hostname).and_return("k8s.ubicloud.com")
      dns_zone = DnsZone.create_with_id(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)

      expect { nx.create_load_balancer }.to hop("bootstrap_control_plane_vms")

      expect(kubernetes_cluster.api_server_lb.name).to eq "k8scluster-apiserver"
      expect(kubernetes_cluster.api_server_lb.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::IPV4
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname_dns_zone_id).to eq dns_zone.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to eq "k8scluster-apiserver-#{kubernetes_cluster.ubid[-5...]}.k8s.ubicloud.com"
    end

    it "creates a load balancer with dns zone id on development for api server and hops" do
      expect { nx.create_load_balancer }.to hop("bootstrap_control_plane_vms")

      expect(kubernetes_cluster.api_server_lb.name).to eq "k8scluster-apiserver"
      expect(kubernetes_cluster.api_server_lb.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::IPV4
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to be_nil
    end
  end

  describe "#bootstrap_control_plane_vms" do
    it "waits until the load balancer endpoint is set" do
      expect(kubernetes_cluster.api_server_lb).to receive(:hostname).and_return nil
      expect { nx.bootstrap_control_plane_vms }.to nap(5)
    end

    it "hops wait if the target number of CP vms is reached" do
      expect(kubernetes_cluster.api_server_lb).to receive(:hostname).and_return "endpoint"
      expect(kubernetes_cluster).to receive(:cp_vms).and_return [1, 2, 3]
      expect { nx.bootstrap_control_plane_vms }.to hop("wait")
    end

    it "pushes ProvisionKubernetesNode prog to create VMs" do
      expect(kubernetes_cluster).to receive(:endpoint).and_return "endpoint"
      expect(nx).to receive(:push).with(Prog::Kubernetes::ProvisionKubernetesNode)
      nx.bootstrap_control_plane_vms
    end
  end

  describe "#wait" do
    it "naps forever for now" do
      expect { nx.wait }.to nap(65536)
    end
  end

  describe "#destroy" do
    it "triggers deletion of associated resources and naps until all nodepools are gone" do
      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)

      expect(kubernetes_cluster.cp_vms).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.nodepools).to all(receive(:incr_destroy))

      expect(kubernetes_cluster).not_to receive(:destroy)
      expect { nx.destroy }.to nap(5)
    end

    it "completes destroy when nodepools are gone" do
      kubernetes_cluster.nodepools.first.destroy
      kubernetes_cluster.reload

      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.cp_vms).to all(receive(:incr_destroy))

      expect(kubernetes_cluster.nodepools).to be_empty

      expect { nx.destroy }.to exit({"msg" => "kubernetes cluster is deleted"})
    end
  end
end
