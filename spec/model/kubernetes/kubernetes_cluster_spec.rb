# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    project = Project.create(name: "test")
    private_subnet = PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::HETZNER_FSN1_ID, net6: "fe80::/64", net4: "192.168.0.0/24")
    described_class.create(
      name: "kc-name",
      version: Option.kubernetes_versions.first,
      location_id: Location::HETZNER_FSN1_ID,
      cp_node_count: 3,
      project_id: project.id,
      private_subnet_id: private_subnet.id,
      target_node_size: "standard-2"
    )
  }

  it "displays location properly" do
    expect(kc.display_location).to eq("eu-central-h1")
  end

  it "returns path" do
    expect(kc.path).to eq("/location/eu-central-h1/kubernetes-cluster/kc-name")
  end

  it "initiates a new health monitor session" do
    sshable = instance_double(Sshable)
    expect(kc).to receive(:sshable).and_return(sshable)
    expect(sshable).to receive(:start_fresh_session)
    kc.init_health_monitor_session
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(kc).to receive(:incr_sync_kubernetes_services)
    client = instance_double(Kubernetes::Client)
    expect(kc).to receive(:client).and_return(client)
    expect(client).to receive(:any_lb_services_modified?).and_return(true)

    expect(kc.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")
  end

  it "checks pulse on with no changes to the internal services" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "up",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    client = instance_double(Kubernetes::Client)
    expect(kc).to receive(:client).and_return(client)
    expect(client).to receive(:any_lb_services_modified?).and_return(false)

    expect(kc.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("up")
  end

  it "checks pulse and fails" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    client = instance_double(Kubernetes::Client)
    expect(kc).to receive(:client).and_return(client)
    expect(client).to receive(:any_lb_services_modified?).and_raise Sshable::SshError

    expect(kc.check_pulse(session: session, previous_pulse: pulse)[:reading]).to eq("down")
  end

  describe "#kubectl" do
    it "create a new client" do
      session = instance_double(Net::SSH::Connection::Session)
      expect(kc.client(session: session)).to be_an_instance_of(Kubernetes::Client)
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
      sshable = instance_double(Sshable)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      expect(kc.cp_vms.first).to receive(:sshable).and_return(sshable).twice
      expect(sshable).to receive(:cmd).with("kubectl --kubeconfig <(sudo cat /etc/kubernetes/admin.conf) -n kube-system get secret k8s-access -o jsonpath='{.data.token}' | base64 -d", log: false).and_return("mocked_rbac_token")
      expect(sshable).to receive(:cmd).with("sudo cat /etc/kubernetes/admin.conf", log: false).and_return(kubeconfig)
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
      sshable = instance_double(Sshable, id: "someid")
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id)
      expect(kc.cp_vms.first).to receive(:sshable).and_return(sshable).twice
      kc.cp_vms.each do |vm|
        expect(Strand).to receive(:create).with(prog: "InstallRhizome", label: "start", stack: [{subject_id: vm.sshable.id, target_folder: "kubernetes"}])
      end
      kc.install_rhizome
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
