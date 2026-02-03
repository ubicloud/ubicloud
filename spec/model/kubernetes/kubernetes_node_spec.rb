# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesNode do
  subject(:kn) {
    described_class.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)
  }

  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::HETZNER_FSN1_ID, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kc) {
    KubernetesCluster.create(
      name: "kc-name",
      version: Option.kubernetes_versions.first,
      location_id: Location::HETZNER_FSN1_ID,
      cp_node_count: 1,
      project_id: project.id,
      private_subnet_id: private_subnet.id,
      target_node_size: "standard-2"
    )
  }
  let(:vm) {
    Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test-vm", private_subnet_id: private_subnet.id,
      location_id: Location::HETZNER_FSN1_ID
    )
  }

  let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
  let(:ssh_session) { session[:ssh_session] }

  describe "#init_health_monitor_session" do
    it "initiates a new health monitor session" do
      expect(kn.sshable).to receive(:start_fresh_session).and_return("mock_session")
      session = kn.init_health_monitor_session
      expect(session).to eq({ssh_session: "mock_session"})
    end
  end

  describe "#check_pulse" do
    let(:pulse) {
      {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
    }

    it "returns up when file is empty (CSI not installed yet)" do
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return("")
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns up when all pods are reachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
          "ubicsi-nodeplugin-xyz" => {"ip" => "10.0.0.3", "reachable" => true, "last_check" => Time.now.utc.iso8601}
        }
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns down when any pod is unreachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
          "ubicsi-nodeplugin-xyz" => {"ip" => "10.0.0.3", "reachable" => false, "last_check" => Time.now.utc.iso8601}
        }
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns up when pods hash is empty" do
      status_json = JSON.generate({"node_id" => "node-1", "pods" => {}})
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns down on JSON parse error" do
      expect(ssh_session).to receive(:_exec!).and_return("not valid json {")
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns down on other SSH errors" do
      expect(ssh_session).to receive(:_exec!).and_raise Sshable::SshError
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
      it "reraises the exception for exception class: #{ex.class}" do
        expect(ssh_session).to receive(:_exec!).and_raise(ex)
        expect { kn.check_pulse(session:, previous_pulse: pulse) }.to raise_error(ex)
      end
    end
  end
end
