# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesNode do
  subject(:kn) {
    Prog::Kubernetes::KubernetesNodeNexus.assemble(
      Config.kubernetes_service_project_id,
      sshable_unix_user: "ubi", name: "test-node", location_id: Location::HETZNER_FSN1_ID,
      size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}],
      boot_image: "kubernetes-v1.33", enable_ip4: true,
      kubernetes_cluster_id: kc.id,
    ).subject
  }

  let(:project) { Project.create(name: "test") }
  let(:kc) { Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "kc-name", version: Option.selectable_kubernetes_versions.first, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 1, project_id: project.id, target_node_size: "standard-2").subject }
  let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
  let(:ssh_session) { session[:ssh_session] }
  let(:read_mesh_status) { "cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n" }

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

  describe "#init_metrics_export_session" do
    it "initiates a new metrics export session" do
      expect(kn.sshable).to receive(:start_fresh_session).and_return("mock_session")
      session = kn.init_metrics_export_session
      expect(session).to eq({ssh_session: "mock_session"})
    end
  end

  describe "#metrics_config" do
    it "labels a control plane node with its cluster and role" do
      expect(kn.metrics_config).to eq({
        endpoints: [
          "http://localhost:9100/metrics",
          "http://localhost:9090/federate?match%5B%5D=%7B__name__%3D%7E%22ubicloud%3A.*%22%7D&match%5B%5D=apiserver_current_inflight_requests&match%5B%5D=apiserver_storage_size_bytes&match%5B%5D=scheduler_pending_pods",
        ],
        max_file_retention: 120,
        interval: "15s",
        additional_labels: {
          ubicloud_resource_id: kc.ubid,
          ubicloud_resource_role: "control-plane",
          instance: kn.name,
        },
        exclude_metrics: ["^(# (HELP|TYPE) )?node_scrape_collector_"],
        metrics_dir: "/home/ubi/kubernetes/metrics",
        project_id: Config.kubernetes_service_project_id,
      })
    end

    it "scrapes only node_exporter on a worker node and labels it with its nodepool" do
      nodepool = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id).subject
      kn.update(kubernetes_nodepool_id: nodepool.id)

      expect(kn.reload.metrics_config[:endpoints]).to eq ["http://localhost:9100/metrics"]
      expect(kn.metrics_config[:additional_labels]).to eq({
        ubicloud_resource_id: kc.ubid,
        ubicloud_resource_role: "worker",
        instance: kn.name,
        nodepool: "np",
      })
    end
  end

  describe "#export_metrics" do
    let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

    it "observes the metrics backlog at export counts where count % 12 == 1" do
      session[:export_count] = 12
      allow(kn).to receive(:scrape_endpoints).and_return([])
      expect(kn).to receive(:observe_metrics_backlog).with(session)

      kn.export_metrics(session:, tsdb_client:)
    end

    it "does not observe the metrics backlog when count % 12 != 1" do
      session[:export_count] = 2
      allow(kn).to receive(:scrape_endpoints).and_return([])
      expect(kn).not_to receive(:observe_metrics_backlog)

      kn.export_metrics(session:, tsdb_client:)
    end

    it "increments export_count in session" do
      allow(kn).to receive_messages(observe_metrics_backlog: nil, scrape_endpoints: [])

      kn.export_metrics(session:, tsdb_client:)
      expect(session[:export_count]).to eq 1

      kn.export_metrics(session:, tsdb_client:)
      expect(session[:export_count]).to eq 2
    end
  end

  describe "#observe_metrics_backlog" do
    let(:find_command) { "echo $(date +%s) $(stat -c %Y /home/ubi/kubernetes/metrics/config.json) $(test -d /home/ubi/kubernetes/metrics/done && stat -c %Y /home/ubi/kubernetes/metrics/done || echo 0) $(test -d /home/ubi/kubernetes/metrics/done && ls /home/ubi/kubernetes/metrics/done | wc -l || echo 0)" }
    let(:now) { Time.now.utc.to_i }
    let(:reading) { ->(count, touched_secs_ago: 0, configured_secs_ago: 60 * 60) { "#{now} #{now - configured_secs_ago} #{now - touched_secs_ago} #{count}\n" } }

    it "does nothing when the backlog is within limits" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(10))

      kn.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)).to be_nil
    end

    it "creates a page when the backlog exceeds the threshold" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(30))

      kn.observe_metrics_backlog(session)

      page = Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)
      expect(page.summary).to eq "#{kn.ubid} metrics backlog high"
      expect(page.severity).to eq "warning"
      expect(page.details["metrics_backlog"]).to eq 30
      expect(page.details["related_resources"]).to eq [kn.ubid]
      expect(DB[:page_root_resource].where(page_id: page.id).select_map(:root_resource_id)).to eq [kn.kubernetes_cluster_id]
    end

    it "resolves the page when the backlog is back within limits" do
      Prog::PageNexus.assemble("#{kn.ubid} metrics backlog high", ["KubernetesMetricsBacklogHigh", kn.id], kn.ubid, severity: "warning", extra_data: {metrics_backlog: 30})
      page = Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(10))

      kn.observe_metrics_backlog(session)

      expect(page.semaphores_dataset.map(:name)).to eq ["resolve"]
    end

    it "keeps the page when the backlog is still above the resolve threshold" do
      Prog::PageNexus.assemble("#{kn.ubid} metrics backlog high", ["KubernetesMetricsBacklogHigh", kn.id], kn.ubid, severity: "warning", extra_data: {metrics_backlog: 30})
      page = Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(18))

      kn.observe_metrics_backlog(session)

      expect(page.semaphores_dataset.all).to eq []
    end

    it "pages when the metrics directory is missing" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return("#{now} #{now - 60 * 60} 0 0\n")

      kn.observe_metrics_backlog(session)

      page = Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)
      expect(page.summary).to eq "#{kn.ubid} is not collecting metrics"
      expect(page.severity).to eq "warning"
    end

    it "pages when the directory has not been written to or drained recently" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(0, touched_secs_ago: 20 * 60))

      kn.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id).summary).to eq "#{kn.ubid} is not collecting metrics"
    end

    it "does not page a target whose metrics were only just configured" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return("#{now} #{now - 30} 0 0\n")

      kn.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)).to be_nil
    end

    it "does nothing when the exporter has just drained the directory" do
      expect(ssh_session).to receive(:_exec!).with(find_command).and_return(reading.call(0))

      kn.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("KubernetesMetricsBacklogHigh", kn.id)).to be_nil
    end
  end

  describe "#check_pulse" do
    let(:pulse) {
      {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30,
      }
    }
    let(:unreachable_pod_status) {
      JSON.generate({
        "node_id" => "node-1",
        "pods" => {"ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => false}},
      })
    }

    it "returns up when file is empty (CSI not installed yet)" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return("")
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns up when all pods are reachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
          "ubicsi-nodeplugin-xyz" => {"ip" => "10.0.0.3", "reachable" => true, "last_check" => Time.now.utc.iso8601},
        },
        "external_endpoints" => {},
      })
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns down when any pod is unreachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
          "ubicsi-nodeplugin-xyz" => {"ip" => "10.0.0.3", "reachable" => false, "last_check" => Time.now.utc.iso8601},
        },
      })
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns up when pods hash is empty" do
      status_json = JSON.generate({"node_id" => "node-1", "pods" => {}, "external_endpoints" => {}})
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "returns down on JSON parse error" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return("not valid json {")
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns down on other SSH errors" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_raise Sshable::SshError
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
      it "reraises the exception for exception class: #{ex.class}" do
        expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_raise(ex)
        expect { kn.check_pulse(session:, previous_pulse: pulse) }.to raise_error(ex)
      end
    end

    it "returns down when any external endpoint is unreachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
        },
        "external_endpoints" => {
          "10.20.30.40:443" => {"reachable" => true, "last_check" => Time.now.utc.iso8601},
          "api.example.com:8080" => {"reachable" => false, "last_check" => Time.now.utc.iso8601},
        },
      })
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("down")
    end

    it "returns up when all external endpoints are reachable" do
      status_json = JSON.generate({
        "node_id" => "node-1",
        "pods" => {
          "ubicsi-nodeplugin-abc" => {"ip" => "10.0.0.2", "reachable" => true, "last_check" => Time.now.utc.iso8601},
        },
        "external_endpoints" => {
          "10.20.30.40:443" => {"reachable" => true, "last_check" => Time.now.utc.iso8601},
          "api.example.com:8080" => {"reachable" => true, "last_check" => Time.now.utc.iso8601},
        },
      })
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(status_json)
      expect(kn.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
    end

    it "increments checkup semaphore after sustained down readings" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(unreachable_pod_status)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 31}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.checkup_set?(cached: false)).to be true
    end

    it "keeps a single checkup semaphore when one was set after the node was loaded" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(unreachable_pod_status)
      expect(kn.checkup_set?).to be false
      described_class[kn.id].incr_checkup

      kn.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 6, reading_chg: Time.now - 31})
      expect(Semaphore.where(strand_id: kn.id, name: "checkup").count).to eq 1
    end

    it "does not increment checkup when reading_rpt is too low" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(unreachable_pod_status)

      previous_pulse = {reading: "down", reading_rpt: 4, reading_chg: Time.now - 31}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.checkup_set?(cached: false)).to be false
    end

    it "does not increment checkup when reading_chg is too recent" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(unreachable_pod_status)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 10}

      kn.check_pulse(session:, previous_pulse:)
      expect(kn.checkup_set?(cached: false)).to be false
    end

    it "does not increment checkup when checkup is already set" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return(unreachable_pod_status)

      previous_pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 31}
      kn.incr_checkup

      kn.check_pulse(session:, previous_pulse:)
      expect(Semaphore.where(strand_id: kn.id, name: "checkup").count).to eq 1
    end
  end

  describe "#available?" do
    it "returns true when mesh is available" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => true}}, "external_endpoints" => {}})
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)
      expect(kn.available?).to be true
    end

    it "returns false when mesh is not available" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => false}}, "external_endpoints" => {}})
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)
      expect(kn.available?).to be false
    end

    it "returns false on any error" do
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_raise(Sshable::SshError)
      expect(kn.available?).to be false
    end
  end

  describe "#check_mesh_availability" do
    it "returns available when file is empty" do
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return("")
      expect(kn.check_mesh_availability).to eq({available: true})
    end

    it "returns available when all pods are reachable" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => true}},
        "external_endpoints" => {},
      })
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)
      expect(kn.check_mesh_availability).to eq({available: true})
    end

    it "returns not available with details when pods are unreachable" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => false, "error" => "timeout"}},
        "external_endpoints" => {},
        "mtr_results" => {"pod-1" => {"ip" => "10.0.0.2", "output" => "HOST: ...", "exit_status" => 0, "last_check" => "2026-01-01T00:00:00Z"}},
      })
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)

      expect(kn.check_mesh_availability).to eq({
        available: false,
        unreachable_pods: ["pod-1"],
        unreachable_external: [],
        pod_errors: [{"name" => "pod-1", "reachable" => false, "error" => "timeout"}],
        external_errors: [],
        mtr_results: [{"name" => "pod-1", "ip" => "10.0.0.2", "output" => "HOST: ...", "exit_status" => 0, "last_check" => "2026-01-01T00:00:00Z"}],
      })
    end

    it "returns not available when api_error is present" do
      status_json = JSON.generate({
        "pods" => {"pod-1" => {"reachable" => true}},
        "external_endpoints" => {},
        "mtr_results" => {},
        "api_error" => "connection refused",
      })
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)

      expect(kn.check_mesh_availability).to eq({available: false, api_error: "connection refused", mtr_results: []})
    end

    it "returns not available when external endpoints are unreachable" do
      status_json = JSON.generate({
        "pods" => {},
        "external_endpoints" => {"10.0.0.1:443" => {"reachable" => false, "error" => "connection refused"}},
      })
      expect(kn.sshable).to receive(:_cmd).with(read_mesh_status).and_return(status_json)

      expect(kn.check_mesh_availability).to eq({
        available: false,
        unreachable_pods: [],
        unreachable_external: ["10.0.0.1:443"],
        pod_errors: [],
        external_errors: [{"name" => "10.0.0.1:443", "reachable" => false, "error" => "connection refused"}],
        mtr_results: nil,
      })
    end

    it "uses ssh_session when provided" do
      expect(ssh_session).to receive(:_exec!).with(read_mesh_status).and_return("")
      expect(kn.check_mesh_availability(ssh_session)).to eq({available: true})
    end
  end

  describe "#install_rhizome" do
    it "creates an InstallRhizome strand" do
      st = kn.install_rhizome
      expect(st).to have_attributes(prog: "InstallRhizome", label: "start")
      expect(st.stack).to eq [{"subject_id" => kn.vm.sshable.id, "target_folder" => "kubernetes"}]
    end
  end

  describe "#cert_expire_at" do
    it "reads and parses the apiserver cert expiry from the node as UTC" do
      expect(kn.sshable).to receive(:_cmd).with("sudo openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt").and_return("notAfter=May 21 19:50:47 2027 GMT\n")
      expect(kn.cert_expire_at).to eq(Time.utc(2027, 5, 21, 19, 50, 47))
    end

    it "handles single-digit days padded with a space" do
      expect(kn.sshable).to receive(:_cmd).with("sudo openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt").and_return("notAfter=Jun  8 12:08:01 2027 GMT\n")
      expect(kn.cert_expire_at).to eq(Time.utc(2027, 6, 8, 12, 8, 1))
    end
  end
end
