# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesClusterNexus do
  subject(:nx) { described_class.new(Strand.new) }

  let(:customer_project) { Project.create(name: "default") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id) }

  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: customer_project.id,
      target_node_size: "standard-2"
    )
    KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)
    kc.update(api_server_lb_id: lb.id)
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(nx).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(project_id: "88c8beda-0718-82d2-9948-7569acc26b80", name: "k8stest", version: "v1.32", location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(version: "v1.30", project_id: customer_project.id, name: "k8stest", location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Invalid Kubernetes Version"

      expect {
        described_class.assemble(name: "Uppercase", version: "v1.32", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "hyph_en", version: "v1.32", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "onetoolongnameforatestkubernetesclustername", version: "v1.32", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "somename", version: "v1.32", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 2, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: control_plane_node_count"

      p = Project.create(name: "another")
      subnet.update(project_id: p.id)
      expect {
        described_class.assemble(name: "normalname", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the k8s project"
    end

    it "creates a kubernetes cluster" do
      st = described_class.assemble(name: "k8stest", version: "v1.31", private_subnet_id: subnet.id, project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, target_node_size: "standard-8", target_node_storage_size_gib: 100)

      kc = st.subject
      expect(kc.name).to eq "k8stest"
      expect(kc.ubid).to start_with("kc")
      expect(kc.version).to eq "v1.31"
      expect(kc.location_id).to eq Location::HETZNER_FSN1_ID
      expect(kc.cp_node_count).to eq 3
      expect(kc.private_subnet.id).to eq subnet.id
      expect(kc.project.id).to eq customer_project.id
      expect(kc.strand.label).to eq "start"
      expect(kc.target_node_size).to eq "standard-8"
      expect(kc.target_node_storage_size_gib).to eq 100
    end

    it "has defaults for node size, storage size, version and subnet" do
      st = described_class.assemble(name: "k8stest", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3)
      kc = st.subject

      expect(kc.version).to eq "v1.32"
      expect(kc.private_subnet.net4.to_s[-3..]).to eq "/18"
      expect(kc.private_subnet.name).to eq kc.ubid.to_s + "-subnet"
      expect(kc.target_node_size).to eq "standard-2"
      expect(kc.target_node_storage_size_gib).to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect { nx.create_billing_records }.to hop("wait")
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(kubernetes_cluster.active_billing_records).not_to be_empty
      expect(kubernetes_cluster.active_billing_records).to all(receive(:finalize))
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
      dns_zone = DnsZone.create(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)

      expect { nx.create_load_balancer }.to hop("bootstrap_control_plane_vms")

      expect(kubernetes_cluster.api_server_lb.name).to eq "#{kubernetes_cluster.ubid}-apiserver"
      expect(kubernetes_cluster.api_server_lb.ports.first.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.ports.first.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::DUAL
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname_dns_zone_id).to eq dns_zone.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to eq "k8scluster-apiserver-#{kubernetes_cluster.ubid[-5...]}.k8s.ubicloud.com"
    end

    it "creates a load balancer with dns zone id on development for api server and hops" do
      expect { nx.create_load_balancer }.to hop("bootstrap_control_plane_vms")

      expect(kubernetes_cluster.api_server_lb.name).to eq "#{kubernetes_cluster.ubid}-apiserver"
      expect(kubernetes_cluster.api_server_lb.ports.first.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.ports.first.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::DUAL
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to be_nil
    end
  end

  describe "#bootstrap_control_plane_vms" do
    it "waits until the load balancer endpoint is set" do
      expect(kubernetes_cluster.api_server_lb).to receive(:hostname).and_return nil
      expect { nx.bootstrap_control_plane_vms }.to nap(5)
    end

    it "incrs start_bootstrapping on KubernetesNodepool on 3 node control plane setup" do
      expect(kubernetes_cluster).to receive(:cp_vms).and_return([create_vm, create_vm, create_vm]).twice
      expect(kubernetes_cluster.nodepools.first).to receive(:incr_start_bootstrapping)
      expect { nx.bootstrap_control_plane_vms }.to hop("wait_nodes")
    end

    it "incrs start_bootstrapping on KubernetesNodepool on 1 node control plane setup" do
      kubernetes_cluster.update(cp_node_count: 1)
      expect(kubernetes_cluster).to receive(:cp_vms).and_return([create_vm]).twice
      expect(kubernetes_cluster.nodepools.first).to receive(:incr_start_bootstrapping)
      expect { nx.bootstrap_control_plane_vms }.to hop("wait_nodes")
    end

    it "hops wait_nodes if the target number of CP vms is reached" do
      expect(kubernetes_cluster.api_server_lb).to receive(:hostname).and_return "endpoint"
      expect(kubernetes_cluster).to receive(:cp_vms).and_return([1, 2, 3]).twice
      expect { nx.bootstrap_control_plane_vms }.to hop("wait_nodes")
    end

    it "buds ProvisionKubernetesNode prog to create VMs" do
      expect(kubernetes_cluster).to receive(:endpoint).and_return "endpoint"
      expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id})
      expect { nx.bootstrap_control_plane_vms }.to hop("wait_control_plane_node")
    end
  end

  describe "#wait_control_plane_node" do
    before { expect(nx).to receive(:reap) }

    it "hops back to bootstrap_control_plane_vms if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_control_plane_node }.to hop("bootstrap_control_plane_vms")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_control_plane_node }.to nap(1)
    end
  end

  describe "#wait_nodes" do
    it "naps until all nodepools are ready" do
      expect(kubernetes_cluster.nodepools.first).to receive(:strand).and_return(instance_double(Strand, label: "not_wait"))
      expect { nx.wait_nodes }.to nap(10)
    end

    it "hops to create_billing_records when all nodepools are ready" do
      expect(kubernetes_cluster.nodepools.first).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait_nodes }.to hop("create_billing_records")
    end
  end

  describe "#create_billing_records" do
    it "creates billing records for all cp vms and nodepools" do
      kubernetes_cluster.nodepools.first.add_vm(create_vm)

      expect { nx.create_billing_records }.to hop("wait")

      expect(kubernetes_cluster.active_billing_records.length).to eq 4

      expect(kubernetes_cluster.active_billing_records.map { it.billing_rate["resource_type"] }).to eq ["KubernetesControlPlaneVCpu", "KubernetesControlPlaneVCpu", "KubernetesWorkerVCpu", "KubernetesWorkerStorage"]
    end
  end

  describe "#sync_kubernetes_services" do
    it "calls the sync_kubernetes_services function" do
      client = instance_double(Kubernetes::Client)
      expect(nx).to receive(:decr_sync_kubernetes_services)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:sync_kubernetes_services)
      expect { nx.sync_kubernetes_services }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to the right sync_kubernetes_service when its semaphore is set" do
      expect(nx).to receive(:when_sync_kubernetes_services_set?).and_yield
      expect { nx.wait }.to hop("sync_kubernetes_services")
    end

    it "naps until sync_kubernetes_service is set" do
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

    it "triggers deletion of associated resources and naps until all nodepools are gone" do
      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)

      expect(kubernetes_cluster.cp_vms).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.nodepools).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.private_subnet).to receive(:incr_destroy)

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
