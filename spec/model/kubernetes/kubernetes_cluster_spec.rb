# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    project = Project.create(name: "test")
    private_subnet = PrivateSubnet.create(project_id: project.id, name: "test", location: "hetzner-hel1", net6: "fe80::/64", net4: "192.168.0.0/24")
    described_class.create(
      name: "kc-name",
      version: "v1.32",
      location: "hetzner-fsn1",
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
      expect(kc.errors[:cp_node_count]).to eq(["must be greater than 0"])

      kc.cp_node_count = 2
      expect(kc.valid?).to be true
    end

    it "validates version" do
      kc.version = "v1.33"
      expect(kc.valid?).to be false
      expect(kc.errors[:version]).to eq(["must be a valid Kubernetes version"])

      kc.version = "v1.32"
      expect(kc.valid?).to be true
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
    let(:sshable) { instance_double(Sshable) }
    let(:vm) { instance_double(Vm, sshable: sshable) }
    let(:cp_vms) { [vm] }

    it "removes client certificate and key data from users and adds an RBAC token to users" do
      expect(kc).to receive(:cp_vms).and_return(cp_vms)
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
end
