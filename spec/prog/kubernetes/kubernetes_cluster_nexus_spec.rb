# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesClusterNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77") }

  let(:customer_project) { Project.create(name: "default") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id) }

  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: customer_project.id,
      target_node_size: "standard-2"
    )
    KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")

    dns_zone = DnsZone.create(project_id: Project.first.id, name: "somezone", last_purged_at: Time.now)

    apiserver_lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: apiserver_lb.id, src_port: 123, dst_port: 456)
    [create_vm, create_vm].each do |vm|
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)
    end
    kc.update(api_server_lb_id: apiserver_lb.id)

    services_lb = Prog::Vnet::LoadBalancerNexus.assemble(
      subnet.id,
      name: "somelb2",
      algorithm: "hash_based",
      # TODO: change the api to support LBs without ports
      # The next two fields will be later modified by the sync_kubernetes_services label
      # These are just set for passing the creation validations
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/",
      health_check_protocol: "tcp",
      custom_hostname_dns_zone_id: dns_zone.id,
      custom_hostname_prefix: "someprefix",
      stack: LoadBalancer::Stack::IPV4
    ).subject

    kc.update(services_lb_id: services_lb.id)
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(nx).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(project_id: "88c8beda-0718-82d2-9948-7569acc26b80", name: "k8stest", location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(version: "v1.30", project_id: customer_project.id, name: "k8stest", location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Invalid Kubernetes Version"

      expect {
        described_class.assemble(name: "Uppercase", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "hyph_en", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "onetoolongnameforatestkubernetesclustername", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(name: "somename", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 2, private_subnet_id: subnet.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: control_plane_node_count"

      p = Project.create(name: "another")
      subnet.update(project_id: p.id)
      expect {
        described_class.assemble(name: "normalname", project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, private_subnet_id: subnet.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the k8s project"
    end

    it "creates a kubernetes cluster" do
      st = described_class.assemble(name: "k8stest", version: Option.kubernetes_versions.first, private_subnet_id: subnet.id, project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, target_node_size: "standard-8", target_node_storage_size_gib: 100)

      kc = st.subject
      expect(kc.name).to eq "k8stest"
      expect(kc.ubid).to start_with("kc")
      expect(kc.version).to eq Option.kubernetes_versions.first
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

      expect(kc.version).to eq Option.kubernetes_versions.first
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
      expect(nx).to receive(:incr_install_metrics_server)
      expect(nx).to receive(:incr_sync_worker_mesh)
      expect(nx).not_to receive(:incr_install_csi)
      expect { nx.start }.to hop("create_load_balancers")
    end

    it "also increments install_csi when its feature flag is set" do
      customer_project.set_ff_install_csi(true)
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:incr_install_metrics_server)
      expect(nx).to receive(:incr_sync_worker_mesh)
      expect(nx).to receive(:incr_install_csi)
      expect { nx.start }.to hop("create_load_balancers")
    end
  end

  describe "#create_load_balancers" do
    it "creates api server and services load balancers with the right dns zone on prod and hops" do
      kubernetes_cluster.update(api_server_lb_id: nil, services_lb_id: nil)

      allow(Config).to receive(:kubernetes_service_hostname).and_return("k8s.ubicloud.com")
      dns_zone = DnsZone.create(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)

      expect { nx.create_load_balancers }.to hop("bootstrap_control_plane_nodes")

      expect(kubernetes_cluster.api_server_lb.name).to eq "#{kubernetes_cluster.ubid}-apiserver"
      expect(kubernetes_cluster.api_server_lb.ports.first.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.ports.first.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::DUAL
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname_dns_zone_id).to eq dns_zone.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to eq "k8scluster-apiserver-#{kubernetes_cluster.ubid[-5...]}.k8s.ubicloud.com"

      expect(kubernetes_cluster.services_lb.name).to eq "#{kubernetes_cluster.ubid}-services"
      expect(kubernetes_cluster.services_lb.stack).to eq LoadBalancer::Stack::DUAL
      expect(kubernetes_cluster.services_lb.ports.count).to eq 0
      expect(kubernetes_cluster.services_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.services_lb.custom_hostname_dns_zone_id).to eq dns_zone.id
      expect(kubernetes_cluster.services_lb.custom_hostname).to eq "k8scluster-services-#{kubernetes_cluster.ubid[-5...]}.k8s.ubicloud.com"
    end

    it "creates load balancers with dns zone id on development for api server and services, then hops" do
      expect { nx.create_load_balancers }.to hop("bootstrap_control_plane_nodes")

      expect(kubernetes_cluster.api_server_lb.name).to eq "#{kubernetes_cluster.ubid}-apiserver"
      expect(kubernetes_cluster.api_server_lb.ports.first.src_port).to eq 443
      expect(kubernetes_cluster.api_server_lb.ports.first.dst_port).to eq 6443
      expect(kubernetes_cluster.api_server_lb.health_check_endpoint).to eq "/healthz"
      expect(kubernetes_cluster.api_server_lb.health_check_protocol).to eq "tcp"
      expect(kubernetes_cluster.api_server_lb.stack).to eq LoadBalancer::Stack::DUAL
      expect(kubernetes_cluster.api_server_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.api_server_lb.custom_hostname).to be_nil

      expect(kubernetes_cluster.services_lb.name).to eq "#{kubernetes_cluster.ubid}-services"
      expect(kubernetes_cluster.services_lb.private_subnet_id).to eq subnet.id
      expect(kubernetes_cluster.services_lb.custom_hostname).to be_nil
    end
  end

  describe "#bootstrap_control_plane_nodes" do
    it "waits until the load balancer endpoint is set" do
      expect(kubernetes_cluster.api_server_lb).to receive(:hostname).and_return nil
      expect { nx.bootstrap_control_plane_nodes }.to nap(5)
    end

    it "creates a prog for the first control plane node" do
      expect(kubernetes_cluster).to receive(:nodes).and_return([]).twice
      expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id})
      expect { nx.bootstrap_control_plane_nodes }.to hop("wait_control_plane_node")
    end

    it "incrs start_bootstrapping on KubernetesNodepool on 3 node control plane setup" do
      expect(kubernetes_cluster).to receive(:nodes).and_return([1, 2, 3]).twice
      expect(kubernetes_cluster.nodepools.first).to receive(:incr_start_bootstrapping)
      expect { nx.bootstrap_control_plane_nodes }.to hop("wait_nodes")
    end

    it "incrs start_bootstrapping on KubernetesNodepool on 1 node control plane setup" do
      kubernetes_cluster.update(cp_node_count: 1)
      expect(kubernetes_cluster).to receive(:nodes).and_return([1]).twice
      expect(kubernetes_cluster.nodepools.first).to receive(:incr_start_bootstrapping)
      expect { nx.bootstrap_control_plane_nodes }.to hop("wait_nodes")
    end

    it "hops wait_nodes if the target number of CP nodes is reached" do
      expect(kubernetes_cluster).to receive(:nodes).and_return([1, 2, 3]).twice
      expect { nx.bootstrap_control_plane_nodes }.to hop("wait_nodes")
    end

    it "buds ProvisionKubernetesNode prog to create Nodes" do
      kubernetes_cluster.nodes.last.destroy
      expect(kubernetes_cluster).to receive(:endpoint).and_return "endpoint"
      expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"subject_id" => kubernetes_cluster.id})
      expect { nx.bootstrap_control_plane_nodes }.to hop("wait_control_plane_node")
    end
  end

  describe "#wait_control_plane_node" do
    it "hops back to bootstrap_control_plane_nodes if there are no sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "wait_control_plane_node", stack: [{}])
      expect { nx.wait_control_plane_node }.to hop("bootstrap_control_plane_nodes")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "wait_control_plane_node", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_control_plane_node }.to nap(120)
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
    it "creates billing records for all control plane nodes and nodepool nodes" do
      vm = create_vm
      nodepool = kubernetes_cluster.nodepools.first
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: nodepool.id)

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

    it "hops to upgrade when semaphore is set" do
      expect(nx).to receive(:when_upgrade_set?).and_yield
      expect { nx.wait }.to hop("upgrade")
    end

    it "hops to install_metrics_server when semaphore is set" do
      expect(nx).to receive(:when_install_metrics_server_set?).and_yield
      expect { nx.wait }.to hop("install_metrics_server")
    end

    it "hops to sync_worker_mesh when semaphore is set" do
      expect(nx).to receive(:when_sync_worker_mesh_set?).and_yield
      expect { nx.wait }.to hop("sync_worker_mesh")
    end

    it "hops to install_csi when semaphore is set" do
      expect(nx).to receive(:when_install_csi_set?).and_yield
      expect { nx.wait }.to hop("install_csi")
    end

    it "naps until sync_kubernetes_service or upgrade is set" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#upgrade" do
    let(:first_node) { kubernetes_cluster.nodes[0] }
    let(:second_node) { kubernetes_cluster.nodes[1] }
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      sshable0, sshable1 = instance_double(Sshable), instance_double(Sshable)
      expect(first_node).to receive(:sshable).and_return(sshable0).at_least(:once)
      allow(second_node).to receive(:sshable).and_return(sshable1)
      allow(sshable0).to receive(:connect)
      allow(sshable1).to receive(:connect)

      expect(kubernetes_cluster).to receive(:client).and_return(client).at_least(:once)
    end

    it "selects a Node with minor version one less than the cluster's version" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.32", "v1.31")
      expect(nx).to receive(:bud).with(Prog::Kubernetes::UpgradeKubernetesNode, {"old_node_id" => second_node.id})
      expect { nx.upgrade }.to hop("wait_upgrade")
    end

    it "hops to wait when all nodes are at the cluster's version" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.32", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "does not select a node with minor version more than one less than the cluster's version" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.30", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "skips node with invalid version formats" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("invalid", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end

    it "selects the first node that is one minor version behind" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32")
      expect(client).to receive(:version).and_return("v1.31")
      expect(nx).to receive(:bud).with(Prog::Kubernetes::UpgradeKubernetesNode, {"old_node_id" => first_node.id})
      expect { nx.upgrade }.to hop("wait_upgrade")
    end

    it "hops to wait if cluster version is invalid" do
      expect(kubernetes_cluster).to receive(:version).and_return("invalid").twice
      expect(client).to receive(:version).and_return("v1.31", "v1.31")
      expect { nx.upgrade }.to hop("wait")
    end

    it "does not select a node with a higher minor version than the cluster" do
      expect(kubernetes_cluster).to receive(:version).and_return("v1.32").twice
      expect(client).to receive(:version).and_return("v1.33", "v1.32")
      expect { nx.upgrade }.to hop("wait")
    end
  end

  describe "#wait_upgrade" do
    it "hops back to upgrade if there are no sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      expect { nx.wait_upgrade }.to hop("upgrade")
    end

    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_upgrade }.to nap(120)
    end
  end

  describe "#install_metrics_server" do
    let(:sshable) { instance_double(Sshable) }
    let(:node) { KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kubernetes_cluster.id) }

    before do
      allow(kubernetes_cluster.cp_vms.first).to receive(:sshable).and_return(sshable)
    end

    it "runs install_metrics_server and naps when not started" do
      expect(sshable).to receive(:d_check).with("install_metrics_server").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("install_metrics_server", "kubernetes/bin/install-metrics-server")
      expect { nx.install_metrics_server }.to nap(30)
    end

    it "hops when metrics server install succeeds" do
      expect(sshable).to receive(:d_check).with("install_metrics_server").and_return("Succeeded")
      expect { nx.install_metrics_server }.to hop("wait")
    end

    it "naps when install_metrics_server is in progress" do
      expect(sshable).to receive(:d_check).with("install_metrics_server").and_return("InProgress")
      expect { nx.install_metrics_server }.to nap(10)
    end

    it "naps forever when install_metrics_server fails" do
      expect(sshable).to receive(:d_check).with("install_metrics_server").and_return("Failed")
      expect { nx.install_metrics_server }.to nap(65536)
    end

    it "naps forever when daemonizer2 returns something unknown" do
      expect(sshable).to receive(:d_check).with("install_metrics_server").and_return("SomethingElse")
      expect { nx.install_metrics_server }.to nap(65536)
    end
  end

  describe "#sync_worker_mesh" do
    let(:first_vm) { Prog::Vm::Nexus.assemble_with_sshable(customer_project.id).subject }
    let(:first_node) { KubernetesNode.create(vm_id: first_vm.id, kubernetes_cluster_id: kubernetes_cluster.id) }
    let(:first_ssh_key) { SshKey.generate }
    let(:second_vm) { Prog::Vm::Nexus.assemble_with_sshable(customer_project.id).subject }
    let(:second_node) { KubernetesNode.create(vm_id: second_vm.id, kubernetes_cluster_id: kubernetes_cluster.id) }
    let(:second_ssh_key) { SshKey.generate }

    before do
      expect(kubernetes_cluster).to receive(:worker_vms).and_return([first_node, second_node]).at_least(:once)
      expect(SshKey).to receive(:generate).and_return(first_ssh_key, second_ssh_key)
    end

    it "creates full mesh connectivity on cluster worker nodes" do
      expect(kubernetes_cluster.worker_vms.first.sshable).to receive(:cmd).with("tee ~/.ssh/id_ed25519 > /dev/null && chmod 0600 ~/.ssh/id_ed25519", stdin: first_ssh_key.private_key)
      expect(kubernetes_cluster.worker_vms.first.sshable).to receive(:cmd).with("tee ~/.ssh/authorized_keys > /dev/null && chmod 0600 ~/.ssh/authorized_keys", stdin: [first_vm.sshable.keys.first.public_key, first_ssh_key.public_key, second_ssh_key.public_key].join("\n"))

      expect(kubernetes_cluster.worker_vms.last.sshable).to receive(:cmd).with("tee ~/.ssh/id_ed25519 > /dev/null && chmod 0600 ~/.ssh/id_ed25519", stdin: second_ssh_key.private_key)
      expect(kubernetes_cluster.worker_vms.last.sshable).to receive(:cmd).with("tee ~/.ssh/authorized_keys > /dev/null && chmod 0600 ~/.ssh/authorized_keys", stdin: [kubernetes_cluster.worker_vms.last.sshable.keys.first.public_key, first_ssh_key.public_key, second_ssh_key.public_key].join("\n"))

      expect { nx.sync_worker_mesh }.to hop("wait")
    end
  end

  describe "#install_csi" do
    it "installs the ubicsi on the cluster" do
      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:kubectl).with("apply -f kubernetes/manifests/ubicsi")
      expect { nx.install_csi }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "donates if there are sub-programs running (Provision...)" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.destroy }.to nap(120)
    end

    it "triggers deletion of associated resources and naps until all nodepools are gone" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.services_lb).to receive(:incr_destroy)

      expect(kubernetes_cluster.nodes).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.cp_vms).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.nodepools).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.private_subnet).to receive(:incr_destroy)

      expect(kubernetes_cluster).not_to receive(:destroy)
      expect { nx.destroy }.to nap(5)
    end

    it "triggers deletion of associated resources and naps until all control plane nodes are gone" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      kubernetes_cluster.nodepools.first.destroy
      kubernetes_cluster.reload

      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.services_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.nodes).to all(receive(:incr_destroy))

      expect(kubernetes_cluster.nodepools).to be_empty

      expect { nx.destroy }.to nap(5)
    end

    it "completes destroy when nodepools are gone" do
      st.update(prog: "Kubernetes::KubernetesClusterNexus", label: "destroy", stack: [{}])
      kubernetes_cluster.nodepools.first.destroy
      kubernetes_cluster.nodes.map(&:destroy)
      kubernetes_cluster.reload

      expect(kubernetes_cluster.api_server_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.services_lb).to receive(:incr_destroy)
      expect(kubernetes_cluster.cp_vms).to all(receive(:incr_destroy))
      expect(kubernetes_cluster.nodes).to all(receive(:incr_destroy))

      expect(kubernetes_cluster.nodepools).to be_empty

      expect { nx.destroy }.to exit({"msg" => "kubernetes cluster is deleted"})
    end

    it "deletes the sub-subdomain DNS record if the DNS zone exists" do
      dns_zone = DnsZone.create(project_id: Project.first.id, name: "k8s.ubicloud.com", last_purged_at: Time.now)
      kubernetes_cluster.services_lb.update(custom_hostname_dns_zone_id: dns_zone.id)

      dns_zone.insert_record(record_name: "*.#{kubernetes_cluster.services_lb.hostname}.", type: "CNAME", ttl: 123, data: "whatever.")
      expect(DnsRecord[name: "*.#{kubernetes_cluster.services_lb.hostname}.", tombstoned: false]).not_to be_nil

      expect { nx.destroy }.to nap(5)
      expect(DnsRecord[name: "*.#{kubernetes_cluster.services_lb.hostname}.", tombstoned: true]).not_to be_nil
    end

    it "does not attempt to delete if dns zone does not exist" do
      kubernetes_cluster.services_lb.update(custom_hostname_dns_zone_id: nil)
      expect { nx.destroy }.to nap(5)
    end

    it "completes the destroy process even if the load balancers do not exist" do
      kubernetes_cluster.update(api_server_lb_id: nil, services_lb_id: nil)
      kubernetes_cluster.nodepools.first.destroy
      kubernetes_cluster.nodes.map(&:destroy)
      kubernetes_cluster.reload
      expect { nx.destroy }.to exit({"msg" => "kubernetes cluster is deleted"})
    end
  end
end
