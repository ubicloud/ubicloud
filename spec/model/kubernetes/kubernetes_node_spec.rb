# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesNode do
  subject(:kn) {
    Prog::Kubernetes::KubernetesNodeNexus.assemble(
      Config.kubernetes_service_project_id,
      sshable_unix_user: "ubi", name: "test-node", location_id: Location::HETZNER_FSN1_ID,
      size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}],
      boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true,
      kubernetes_cluster_id: kc.id
    ).subject
  }

  let(:project) { Project.create(name: "test") }
  let(:subnet) { Prog::Vnet::SubnetNexus.assemble(Config.kubernetes_service_project_id, name: "test-subnet", ipv4_range: "172.19.0.0/16", ipv6_range: "fd40:1a0a:8d48:182a::/64").subject }
  let(:kc) {
    kc = KubernetesCluster.create(
      name: "kc-name",
      version: Option.kubernetes_versions.first,
      location_id: Location::HETZNER_FSN1_ID,
      cp_node_count: 1,
      project_id: project.id,
      private_subnet_id: subnet.id,
      target_node_size: "standard-2"
    )
    Firewall.create(name: "#{kc.ubid}-cp-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
    Firewall.create(name: "#{kc.ubid}-worker-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
    kc
  }
  let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
  let(:ssh_session) { session[:ssh_session] }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

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
        },
        "external_endpoints" => {}
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
      status_json = JSON.generate({"node_id" => "node-1", "pods" => {}, "external_endpoints" => {}})
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns down on JSON parse error" do
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return("not valid json {")
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns down on other SSH errors" do
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_raise Sshable::SshError
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
      it "reraises the exception for exception class: #{ex.class}" do
        expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_raise(ex)
        expect { kn.check_pulse(session:, previous_pulse: pulse) }.to raise_error(ex)
      end
    end

    it "returns down when any external endpoint is unreachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601}
        },
        "external_endpoints" => {
          "10.20.30.40:443" => {"reachable" => true, "last_check" => Time.now.utc.iso8601},
          "api.example.com:8080" => {"reachable" => false, "last_check" => Time.now.utc.iso8601}
        }
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns up when all external endpoints are reachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601}
        },
        "external_endpoints" => {
          "10.20.30.40:443" => {"reachable" => true, "last_check" => Time.now.utc.iso8601},
          "api.example.com:8080" => {"reachable" => true, "last_check" => Time.now.utc.iso8601}
        }
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "increments checkup semaphore after sustained down readings" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {"ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => false}}
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 31}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.reload.checkup_set?).to be true
    end

    it "does not increment checkup when reading_rpt is too low" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {"ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => false}}
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)

      previous_pulse = {reading: "down", reading_rpt: 4, reading_chg: Time.now - 31}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.reload.checkup_set?).to be false
    end

    it "does not increment checkup when reading_chg is too recent" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {"ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => false}}
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 10}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.reload.checkup_set?).to be false
    end

    it "does not increment checkup when checkup is already set" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {"ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => false}}
      })
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 31}
      kn.incr_checkup

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.reload.strand.semaphores.count { it.name == "checkup" }).to eq(1)
    end
  end

  describe "#available?" do
    it "returns true when mesh is available" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => true}}, "external_endpoints" => {}})
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.available?).to be true
    end

    it "returns false when mesh is not available" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => false}}, "external_endpoints" => {}})
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.available?).to be false
    end

    it "returns false on any error" do
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_raise(Sshable::SshError)
      expect(kn.available?).to be false
    end
  end

  describe "#check_mesh_availability" do
    it "returns available when file is empty" do
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return("")
      expect(kn.check_mesh_availability).to eq({available: true})
    end

    it "returns available when all pods are reachable" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => true}},
        "external_endpoints" => {}
      })
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(kn.check_mesh_availability[:available]).to be true
    end

    it "returns not available with details when pods are unreachable" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => false, "error" => "timeout"}},
        "external_endpoints" => {},
        "mtr_results" => {"pod-1" => {"ip" => "10.0.0.2", "output" => "HOST: ...", "exit_status" => 0, "last_check" => "2026-01-01T00:00:00Z"}}
      })
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      result = kn.check_mesh_availability
      expect(result[:available]).to be false
      expect(result[:unreachable_pods]).to eq(["pod-1"])
      expect(result[:pod_errors]).to eq({"pod-1" => "timeout"})
      expect(result[:mtr_results]).to eq({"pod-1" => {"ip" => "10.0.0.2", "output" => "HOST: ...", "exit_status" => 0, "last_check" => "2026-01-01T00:00:00Z"}})
    end

    it "returns not available when api_error is present" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => true}},
        "external_endpoints" => {},
        "mtr_results" => {},
        "api_error" => "connection refused"
      })
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      result = kn.check_mesh_availability
      expect(result[:available]).to be false
      expect(result[:api_error]).to eq("connection refused")
    end

    it "returns not available when external endpoints are unreachable" do
      status_json = JSON.generate({
        "pods" => {},
        "external_endpoints" => {"10.0.0.1:443" => {"reachable" => false}}
      })
      expect(kn.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      result = kn.check_mesh_availability
      expect(result[:available]).to be false
      expect(result[:unreachable_external]).to eq(["10.0.0.1:443"])
    end

    it "uses ssh_session when provided" do
      expect(ssh_session).to receive(:_exec!).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return("")
      expect(kn.check_mesh_availability(ssh_session)).to eq({available: true})
    end
  end

  describe "#install_rhizome" do
    it "creates an InstallRhizome strand" do
      st = kn.install_rhizome
      expect(st).to have_attributes(prog: "InstallRhizome", label: "start")
      expect(st.stack.first).to include("subject_id" => kn.vm.sshable.id, "target_folder" => "kubernetes")
    end
  end
end
