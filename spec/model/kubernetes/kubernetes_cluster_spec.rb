# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "kc-name",
      version: Option.selectable_kubernetes_versions.first,
      location_id: Location::HETZNER_FSN1_ID,
      cp_node_count: 3,
      project_id: project.id,
      target_node_size: "standard-2",
    ).subject
  }

  let(:project) { Project.create(name: "test") }

  before {
    allow(Config).to receive(:kubernetes_service_project_id).and_return(project.id)
  }

  it "displays location properly" do
    expect(kc.display_location).to eq("eu-central-h1")
  end

  it "returns path" do
    expect(kc.path).to eq("/location/eu-central-h1/kubernetes-cluster/kc-name")
  end

  it "#display_state shows appropriate state" do
    np = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id).subject

    kc.strand.update(label: "wait")
    np.strand.update(label: "wait")
    kc.reload
    expect(kc.display_state).to eq "creating"

    kc.update(kubeconfig: "stored")
    expect(kc.display_state).to eq "running"

    kc.strand.update(label: "start")
    kc.reload
    expect(kc.display_state).to eq "creating"

    kc.strand.update(label: "upgrade")
    np.strand.update(label: "wait")
    kc.reload
    expect(kc.display_state).to eq "upgrading"

    kc.strand.update(label: "wait_upgrade")
    kc.reload
    expect(kc.display_state).to eq "upgrading"

    kc.strand.update(label: "wait")
    kc.incr_upgrade
    kc.reload
    expect(kc.display_state).to eq "upgrading"
    Semaphore.where(strand_id: kc.id, name: "upgrade").delete

    kc.incr_upgrade_nodepools
    kc.reload
    expect(kc.display_state).to eq "upgrading"
    Semaphore.where(strand_id: kc.id, name: "upgrade_nodepools").delete

    kc.incr_destroy
    kc.reload
    expect(kc.display_state).to eq "deleting"
    Semaphore.dataset.destroy
    kc.incr_destroying
    kc.reload
    expect(kc.display_state).to eq "deleting"
  end

  describe "#request_upgrade" do
    before do
      kc.strand.update(label: "wait")
      kc.update(version: Option.selectable_kubernetes_versions[1])
    end

    it "sets the target version and the upgrade semaphore" do
      candidate = kc.available_upgrade_version

      expect(kc.reload.request_upgrade).to eq(candidate)
      expect(kc.reload.version).to eq(candidate)
      expect(kc.upgrade_set?).to be true
    end

    it "raises when the cluster is not idle" do
      kc.strand.update(label: "upgrade")

      expect { kc.reload.request_upgrade }.to raise_error(RuntimeError, "Cluster #{kc.ubid} is not ready to be upgraded")
      expect(kc.reload.version).to eq(Option.selectable_kubernetes_versions[1])
    end

    it "raises when a nodepool is more than two minor versions behind" do
      kc.update(version: Option.kubernetes_versions.first)
      np = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id).subject
      np.update(version: Option.kubernetes_versions.last)

      expect { kc.reload.request_upgrade }.to raise_error(RuntimeError, "Cluster #{kc.ubid} has nodepools more than two minor versions behind")
      expect(kc.reload.version).to eq(Option.kubernetes_versions.first)
      expect(kc.upgrade_set?).to be false
    end
  end

  it "#ready_for_upgrade? is true only when an upgrade is available and the whole cluster is idle" do
    np1 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np1", node_count: 1, kubernetes_cluster_id: kc.id).subject
    np2 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id).subject
    kc.strand.update(label: "wait")
    np1.strand.update(label: "wait")
    np2.strand.update(label: "wait")
    expect(kc.reload.ready_for_upgrade?).to be false

    kc.update(version: Option.selectable_kubernetes_versions[1])
    expect(kc.reload.ready_for_upgrade?).to be true

    np2.strand.update(label: "bootstrap_worker_nodes")
    expect(kc.reload.ready_for_upgrade?).to be false

    np2.strand.update(label: "upgrade")
    expect(kc.reload.ready_for_upgrade?).to be false

    np2.strand.update(label: "wait")
    kc.incr_upgrade
    expect(kc.reload.ready_for_upgrade?).to be false

    Semaphore.where(strand_id: kc.id, name: "upgrade").delete
    kc.incr_upgrade_nodepools
    expect(kc.reload.ready_for_upgrade?).to be false

    Semaphore.where(strand_id: kc.id, name: "upgrade_nodepools").delete
    np2.incr_upgrade_requested
    expect(kc.reload.ready_for_upgrade?).to be false

    Semaphore.where(strand_id: np2.id, name: "upgrade_requested").delete
    np2.incr_scale_worker_count
    expect(kc.reload.ready_for_upgrade?).to be false

    Semaphore.where(strand_id: np2.id, name: "scale_worker_count").delete
    kc.incr_sync_kubeconfig
    expect(kc.reload.ready_for_upgrade?).to be true
  end

  it "#nodepools_within_version_skew? is true only when every nodepool is within two minor versions of the cluster" do
    np1 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np1", node_count: 1, kubernetes_cluster_id: kc.id).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id)
    expect(kc.nodepools_within_version_skew?).to be true

    np1.update(version: Option.kubernetes_versions[3])
    expect(kc.nodepools_within_version_skew?).to be false

    np1.update(version: Option.kubernetes_versions[2])
    expect(kc.nodepools_within_version_skew?).to be true
  end

  describe "#kubeadm_recorded_version" do
    let(:ssh_session) { Net::SSH::Connection::Session.allocate }
    let(:client) { Kubernetes::Client.new(kc, ssh_session) }

    before { expect(kc).to receive(:client).and_return(client) }

    it "returns the kubernetesVersion field from the kubeadm-config ConfigMap" do
      cluster_config = "apiServer: {}\nkubernetesVersion: v1.34.0\n"
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(cluster_config, 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'").and_return(response)
      expect(kc.kubeadm_recorded_version).to eq("v1.34.0")
    end
  end

  describe "#kubeadm_recorded_minor_version" do
    it "extracts the major.minor portion of the recorded version" do
      expect(kc).to receive(:kubeadm_recorded_version).and_return("v1.34.5")
      expect(kc.kubeadm_recorded_minor_version).to eq("v1.34")
    end

    it "returns nil when the recorded version is missing" do
      expect(kc).to receive(:kubeadm_recorded_version).and_return(nil)
      expect(kc.kubeadm_recorded_minor_version).to be_nil
    end
  end

  it "#display_state shows appropriate state when nodepool is deleted" do
    kc.strand.update(label: "wait")
    kc.update(kubeconfig: "stored")
    expect(kc.nodepools).to be_empty
    expect(kc.display_state).to eq "running"
  end

  describe "#available_upgrade_version" do
    it "returns upgrade version when available" do
      kc.update(version: Option.selectable_kubernetes_versions[1])
      expect(kc.available_upgrade_version).to eq(Option.selectable_kubernetes_versions.first)
    end

    it "returns nil when on latest version" do
      expect(kc.available_upgrade_version).to be_nil
    end
  end

  it "initiates a new health monitor session" do
    sshable = Sshable.new
    expect(kc).to receive(:sshable).and_return(sshable)
    expect(sshable).to receive(:start_fresh_session)
    kc.init_health_monitor_session
  end

  describe "#check_pulse" do
    let(:ssh_session) { Net::SSH::Connection::Session.allocate }
    let(:session) { {ssh_session:} }
    let(:lb) { LoadBalancer.create(private_subnet_id: kc.private_subnet_id, name: "services_lb", health_check_endpoint: "/", project_id: kc.project_id) }
    let(:client) { Kubernetes::Client.new(kc, ssh_session) }
    let(:down_pulse) { {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30} }
    let(:up_pulse) { {reading: "up", reading_rpt: 5, reading_chg: Time.now - 30} }

    before {
      kc.update(services_lb_id: lb.id)
      expect(kc).to receive(:client).and_return(client)
    }

    it "checks pulse" do
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 30000)
      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: down_pulse)[:reading]).to eq("up")
      expect(kc.sync_kubernetes_services_set?(cached: false)).to be true
    end

    it "keeps a single sync_kubernetes_services semaphore across pulses" do
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 30000)
      kc.incr_sync_kubernetes_services
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(pv_response)

      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("up")
      expect(Semaphore.where(strand_id: kc.id, name: "sync_kubernetes_services").count).to eq 1
    end

    it "checks pulse on with no changes to the internal services" do
      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("up")
    end

    it "checks pulse and fails" do
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_raise(Sshable::SshError)
      expect(kc.check_pulse(session:, previous_pulse: down_pulse)[:reading]).to eq("down")
    end

    it "returns down and creates a page when a PV has migration retry count >= 3" do
      pv_json = JSON.generate({"items" => [
        {"metadata" => {"name" => "pv-healthy", "annotations" => {"csi.ubicloud.com/migration-retry-count" => "1"}}},
        {"metadata" => {"name" => "pv-stuck", "annotations" => {"csi.ubicloud.com/migration-retry-count" => "3"}}},
        {"metadata" => {"name" => "pv-no-annotation", "annotations" => {}}},
      ]})

      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(pv_json, 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(pv_response).ordered
      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("down")

      page = Page.from_tag_parts("KubernetesClusterPVMigrationStuck", kc.id)
      expect(page).not_to be_nil
      expect(page.summary).to eq("#{kc.ubid} PV migration stuck")
      expect(page.details["stuck_pvs"]).to eq(["pv-stuck"])
    end

    it "resolves the page when PVs are no longer stuck" do
      Prog::PageNexus.assemble("#{kc.ubid} PV migration stuck",
        ["KubernetesClusterPVMigrationStuck", kc.id], kc.ubid,
        extra_data: {stuck_pvs: ["pv-stuck"]})
      expect(Page.from_tag_parts("KubernetesClusterPVMigrationStuck", kc.id)).not_to be_nil

      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("up")
      page = Page.from_tag_parts("KubernetesClusterPVMigrationStuck", kc.id)
      expect(page.resolve_set?(cached: false)).to be true
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
      it "reraises #{ex.class}" do
        expect(ssh_session).to receive(:_exec!).and_raise(ex)
        expect { kc.check_pulse(session:, previous_pulse: down_pulse) }.to raise_error(ex)
      end
    end
  end

  describe "#kubectl" do
    it "create a new client" do
      session = Net::SSH::Connection::Session.allocate
      expect(kc.client(session:)).to be_an_instance_of(Kubernetes::Client)
    end
  end

  describe "#firewall_rule_diff_for_lb" do
    let(:lb) {
      Prog::Vnet::LoadBalancerNexus.assemble_with_multiple_ports(
        kc.private_subnet_id, ports: [], name: kc.services_load_balancer_name,
        algorithm: "hash_based", health_check_endpoint: "/", health_check_protocol: "tcp",
      ).subject
    }

    it "reports missing keys for ports not yet in the firewall" do
      lb.add_port(443, 31234)
      extra, missing = kc.firewall_rule_diff_for_lb(lb)
      expect(extra).to be_empty
      expect(missing).to eq [["0.0.0.0/0", 443], ["::/0", 443]]
    end

    it "reports extra rules for descriptions whose port is no longer on the LB" do
      kc.internal_worker_vm_firewall.insert_firewall_rule("0.0.0.0/0", Sequel.pg_range(443..443), description: "k8s-svc-lb:443")
      extra, missing = kc.firewall_rule_diff_for_lb(lb)
      expect(missing).to be_empty
      expect(extra.map(&:description)).to eq ["k8s-svc-lb:443"]
    end

    it "ignores rules without the k8s-svc-lb prefix" do
      kc.internal_worker_vm_firewall.insert_firewall_rule("10.0.0.0/8", Sequel.pg_range(5432..5432), description: "operator-added")
      kc.internal_worker_vm_firewall.insert_firewall_rule("172.16.0.0/12", Sequel.pg_range(9999..9999))
      lb.add_port(443, 31234)
      extra, missing = kc.firewall_rule_diff_for_lb(lb)
      expect(extra).to be_empty
      expect(missing).to eq [["0.0.0.0/0", 443], ["::/0", 443]]
    end
  end

  describe "#validate" do
    it "validates cp_node_count" do
      kc.cp_node_count = 0
      expect(kc.valid?).to be false
      expect(kc.errors[:cp_node_count]).to eq(["must be a positive integer"])

      kc.cp_node_count = 2
      expect(kc.valid?).to be true
    end

    it "validates version" do
      kc.version = "v1.30"
      expect(kc.valid?).to be false
      expect(kc.errors[:version]).to eq(["must be a valid Kubernetes version"])

      kc.version = Option.selectable_kubernetes_versions.first
      expect(kc.valid?).to be true
    end

    it "adds error if cp_node_count is nil" do
      kc.cp_node_count = nil
      expect(kc.valid?).to be false
      expect(kc.errors[:cp_node_count]).to include("must be a positive integer")
    end

    it "adds error if cp_node_count is not an integer" do
      kc.cp_node_count = "three"
      expect(kc.valid?).to be false
      expect(kc.errors[:cp_node_count]).to include("must be a positive integer")
    end
  end

  describe "#kubeconfig" do
    kubeconfig = <<~YAML
      apiVersion: v1
      kind: Config
      users:
        - name: admin
          user:
            client-certificate-data: "mocked_cert_data"
            client-key-data: "mocked_key_data"
    YAML

    it "removes client certificate and key data from users and adds an RBAC token to users" do
      sshable = Sshable.new
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      expect(kc.cp_vms.first).to receive(:sshable).and_return(sshable).twice
      expect(sshable).to receive(:_cmd).with("kubectl --kubeconfig <(sudo cat /etc/kubernetes/admin.conf) -n kube-system get secret k8s-access -o jsonpath='{.data.token}' | base64 -d", log: false).and_return("mocked_rbac_token")
      expect(sshable).to receive(:_cmd).with("sudo cat /etc/kubernetes/admin.conf", log: false).and_return(kubeconfig)
      customer_config = kc.generate_kubeconfig
      YAML.safe_load(customer_config)["users"].each do |user|
        expect(user["user"]).not_to have_key("client-certificate-data")
        expect(user["user"]).not_to have_key("client-key-data")
        expect(user["user"]["token"]).to eq("mocked_rbac_token")
      end
    end

    it "supports swallow_connection_exception: true to suppress connection errors" do
      sshable = Sshable.new
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      expect(kc.cp_vms.first).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(sshable).to receive(:_cmd).with("kubectl --kubeconfig <(sudo cat /etc/kubernetes/admin.conf) -n kube-system get secret k8s-access -o jsonpath='{.data.token}' | base64 -d", log: false).and_raise(IOError).twice
      expect { kc.generate_kubeconfig }.to raise_error(IOError)
      expect(kc.generate_kubeconfig(swallow_connection_exception: true)).to be_nil
    end
  end

  describe "vm_diff_for_lb" do
    it "finds the extra and missing nodes" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(kc.private_subnet.id, name: kc.services_load_balancer_name, src_port: 443, dst_port: 8443).subject
      extra_vm = Prog::Vm::Nexus.assemble("k y", kc.project.id, name: "extra-vm", private_subnet_id: kc.private_subnet.id).subject
      missing_vm = Prog::Vm::Nexus.assemble("k y", kc.project.id, name: "missing-vm", private_subnet_id: kc.private_subnet.id).subject
      lb.add_vm(extra_vm)
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      KubernetesNode.create(vm_id: missing_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
      extra_vms, missing_vms = kc.vm_diff_for_lb(lb)
      expect(extra_vms.count).to eq(1)
      expect(extra_vms[0].id).to eq(extra_vm.id)
      expect(missing_vms.count).to eq(1)
      expect(missing_vms[0].id).to eq(missing_vm.id)
    end
  end

  describe "port_diff_for_lb" do
    it "finds the extra and missing nodes" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(kc.private_subnet.id, name: kc.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      extra_ports, missing_ports = kc.port_diff_for_lb(lb, [[443, 8443]])
      expect(extra_ports.count).to eq(1)
      expect(extra_ports[0].src_port).to eq(80)
      expect(missing_ports.count).to eq(1)
      expect(missing_ports[0][0]).to eq(443)
    end
  end

  describe "#install_rhizome" do
    it "creates a strand for each control plane node to update the contents of rhizome folder" do
      node = Prog::Kubernetes::KubernetesNodeNexus.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "test-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-#{kc.version.tr(".", "_")}", enable_ip4: true, kubernetes_cluster_id: kc.id).subject

      result = kc.install_rhizome
      expect(result.count).to eq(1)
      strand = result.first

      expect(strand.prog).to eq "InstallRhizome"
      expect(strand.stack.first["subject_id"]).to eq node.vm.sshable.id
    end
  end

  describe "#all_nodes" do
    it "returns all nodes in the cluster" do
      expect(kc).to receive(:nodes).and_return([1, 2])
      expect(kc).to receive(:nodepools).and_return([instance_double(KubernetesNodepool, nodes: [3, 4]), instance_double(KubernetesNodepool, nodes: [5, 6])])
      expect(kc.all_nodes).to eq([1, 2, 3, 4, 5, 6])
    end
  end

  describe "#worker_vms" do
    it "returns all worker vms in the cluster" do
      expect(kc).to receive(:nodepools).and_return([instance_double(KubernetesNodepool, vms: [3, 4]), instance_double(KubernetesNodepool, vms: [5, 6])])
      expect(kc.worker_vms).to eq([3, 4, 5, 6])
    end
  end

  describe "#functional_nodes" do
    it "includes control-plane nodes in active and renewing_certs states" do
      active = KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, created_at: Time.now - 2)
      renewing = KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, state: "renewing_certs", created_at: Time.now - 1)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, state: "draining")
      expect(kc.reload.functional_nodes.map(&:id)).to eq([active.id, renewing.id])
    end
  end

  describe "#all_functional_nodes_ready?" do
    let(:ssh_session) { Net::SSH::Connection::Session.allocate }
    let(:client) { Kubernetes::Client.new(kc, ssh_session) }
    let(:node) {
      Prog::Kubernetes::KubernetesNodeNexus.assemble(
        project.id,
        sshable_unix_user: "ubi",
        name: "#{kc.ubid}-#{SecureRandom.alphanumeric(5).downcase}",
        location_id: kc.location_id,
        size: kc.target_node_size,
        storage_volumes: [{encrypted: true, size_gib: 40}],
        boot_image: "kubernetes-#{kc.version.tr(".", "_")}",
        enable_ip4: true,
        kubernetes_cluster_id: kc.id,
      ).subject
    }

    before do
      expect(kc).to receive(:client).and_return(client)
    end

    it "returns true when every functional node has Ready=True" do
      body = JSON.generate("items" => [{"metadata" => {"name" => node.name}, "status" => {"conditions" => [{"type" => "Ready", "status" => "True"}]}}])
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -ojson").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(body, 0))
      expect(kc.reload.all_functional_nodes_ready?).to be true
    end

    it "returns false when a functional node reports Ready=False" do
      body = JSON.generate("items" => [{"metadata" => {"name" => node.name}, "status" => {"conditions" => [{"type" => "Ready", "status" => "False"}]}}])
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -ojson").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(body, 0))
      expect(kc.reload.all_functional_nodes_ready?).to be false
    end

    it "returns false when a functional node is missing from the API response" do
      node
      body = JSON.generate("items" => [])
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -ojson").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(body, 0))
      expect(kc.reload.all_functional_nodes_ready?).to be false
    end
  end
end
