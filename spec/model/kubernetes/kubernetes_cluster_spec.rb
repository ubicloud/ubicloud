# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "kc-name",
      version: Option.kubernetes_versions.first,
      location_id: Location::HETZNER_FSN1_ID,
      cp_node_count: 3,
      project_id: project.id,
      private_subnet_id: private_subnet.id,
      target_node_size: "standard-2"
    ).subject
  }

  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::HETZNER_FSN1_ID, net6: "fe80::/64", net4: "192.168.0.0/24") }

  before {
    expect(Config).to receive(:kubernetes_service_project_id).and_return(project.id).twice
  }

  it "displays location properly" do
    expect(kc.display_location).to eq("eu-central-h1")
  end

  it "returns path" do
    expect(kc.path).to eq("/location/eu-central-h1/kubernetes-cluster/kc-name")
  end

  it "#display_state shows appropriate state" do
    kc.strand.update(label: "wait")
    expect(kc.display_state).to eq "running"
    kc.strand.update(label: "start")
    expect(kc.display_state).to eq "creating"
    kc.incr_destroy
    kc.reload
    expect(kc.display_state).to eq "deleting"
    Semaphore.dataset.destroy
    kc.incr_destroying
    kc.reload
    expect(kc.display_state).to eq "deleting"
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
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: down_pulse)[:reading]).to eq("up")
      expect(kc.reload.sync_kubernetes_services_set?).to be true
    end

    it "checks pulse on with no changes to the internal services" do
      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("up")
    end

    it "checks pulse and fails" do
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_raise(Sshable::SshError)
      expect(kc.check_pulse(session:, previous_pulse: down_pulse)[:reading]).to eq("down")
    end

    it "returns down and creates a page when a PV has migration retry count >= 3" do
      pv_json = JSON.generate({"items" => [
        {"metadata" => {"name" => "pv-healthy", "annotations" => {"csi.ubicloud.com/migration-retry-count" => "1"}}},
        {"metadata" => {"name" => "pv-stuck", "annotations" => {"csi.ubicloud.com/migration-retry-count" => "3"}}},
        {"metadata" => {"name" => "pv-no-annotation", "annotations" => {}}}
      ]})

      lb_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate({"items" => []}), 0)
      pv_response = Net::SSH::Connection::Session::StringWithExitstatus.new(pv_json, 0)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(pv_response).ordered
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
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(lb_response).ordered
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(pv_response).ordered

      expect(kc.check_pulse(session:, previous_pulse: up_pulse)[:reading]).to eq("up")
      page = Page.from_tag_parts("KubernetesClusterPVMigrationStuck", kc.id)
      expect(page.reload.resolve_set?).to be true
    end
  end

  describe "#kubectl" do
    it "create a new client" do
      session = Net::SSH::Connection::Session.allocate
      expect(kc.client(session:)).to be_an_instance_of(Kubernetes::Client)
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

      kc.version = Option.kubernetes_versions.first
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
      customer_config = kc.kubeconfig
      YAML.safe_load(customer_config)["users"].each do |user|
        expect(user["user"]).not_to have_key("client-certificate-data")
        expect(user["user"]).not_to have_key("client-key-data")
        expect(user["user"]["token"]).to eq("mocked_rbac_token")
      end
    end
  end

  describe "vm_diff_for_lb" do
    it "finds the extra and missing nodes" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(kc.private_subnet.id, name: kc.services_load_balancer_name, src_port: 443, dst_port: 8443).subject
      extra_vm = Prog::Vm::Nexus.assemble("k y", kc.project.id, name: "extra-vm", private_subnet_id: kc.private_subnet.id).subject
      missing_vm = Prog::Vm::Nexus.assemble("k y", kc.project.id, name: "missing-vm", private_subnet_id: kc.private_subnet.id).subject
      lb.add_vm(extra_vm)
      kn = KubernetesNodepool.create(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
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
    it "creates a strand for each control plane vm to update the contents of rhizome folder" do
      sshable = create_mock_sshable(id: "someid")
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      expect(kc.cp_vms.first).to receive(:sshable).and_return(sshable).twice
      kc.cp_vms.each do |vm|
        expect(Strand).to receive(:create).with(prog: "InstallRhizome", label: "start", stack: [{subject_id: vm.sshable.id, target_folder: "kubernetes"}])
      end
      kc.install_rhizome
    end
  end

  describe "#cluster_health_report" do
    def stub_kubectl(session, command, return_value)
      cmd = "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf #{command}"
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(return_value, 0)
      expect(session).to receive(:_exec!).with(match(cmd)).and_return(response)
    end

    def stub_connectivity_checks(session, fleet)
      fleet.each do |nodename, status|
        case status
        when :success
          stub_kubectl(session,
            "get pods -n ubicsi --field-selector spec.nodeName=#{nodename} -o jsonpath='{.items[*].metadata.name}'",
            "ubicsi-nodeplugin-#{nodename} ubicsi-something-else")

          stub_kubectl(session,
            "exec -n ubicsi ubicsi-nodeplugin-#{nodename} -- sh -c .*",
            "OK-#{nodename}")
        when :failure
          stub_kubectl(session,
            "get pods -n ubicsi --field-selector spec.nodeName=#{nodename} -o jsonpath='{.items[*].metadata.name}'",
            "ubicsi-nodeplugin-#{nodename} ubicsi-something-else")

          stub_kubectl(session,
            "exec -n ubicsi ubicsi-nodeplugin-#{nodename} -- sh -c .*",
            "FAIL")
        when :nocsi
          stub_kubectl(session,
            "get pods -n ubicsi --field-selector spec.nodeName=#{nodename} -o jsonpath='{.items[*].metadata.name}'",
            "someother-pod-abc")
        else
          fail "BUG"
        end
      end
    end

    let(:session) { Net::SSH::Connection::Session.allocate }

    before do
      kn = KubernetesNodepool.create(name: "np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
      kc.update(connectivity_check_target: "example.com:443")
      expect(kc.reload.all_functional_nodes.count).to eq(4)
      allow(kc).to receive(:client).and_return(Kubernetes::Client.new(kc, session))
    end

    it "returns nil when connectivity_check_target is not set" do
      kc.update(connectivity_check_target: nil)
      expect(kc.cluster_health_report).to be_nil
    end

    it "only includes worker nodes, not control plane nodes" do
      kn = kc.nodepools.first
      fleet = kn.nodes.map { [it.name, :success] }
      stub_connectivity_checks(session, fleet)

      report = kc.cluster_health_report
      cp_node = kc.nodes.first

      expect(report.length).to eq(kn.nodes.count)
      expect(report.map { it[:node] }).not_to include(cp_node.ubid)
      expect(report).to all(include(healthy: true))
      expect(report.map { it[:node] }).to eq(kn.nodes.map(&:ubid))
    end

    it "reports nodes as failed if ubicsi plugin is missing or connectivity fails" do
      kn = kc.nodepools.first
      fleet = kn.nodes.map { [it.name, :success] }
      fleet[0][1] = :nocsi
      fleet[1][1] = :failure
      stub_connectivity_checks(session, fleet)

      report = kc.cluster_health_report

      expect(report[0]).to eq(node: kn.nodes[0].ubid, healthy: false)
      expect(report[1]).to eq(node: kn.nodes[1].ubid, healthy: false)
      expect(report[2]).to eq(node: kn.nodes[2].ubid, healthy: true)
    end

    it "returns empty array when there are no worker nodes" do
      kc.nodepools.first.nodes_dataset.destroy
      kc.nodepools_dataset.destroy
      kc.reload

      expect(kc.cluster_health_report).to eq([])
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
end
