# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunner do
  subject(:github_runner) {
    ins = GithubInstallation.create(installation_id: 123, name: "test-installation", type: "User", project_id: Project.create(name: "test").id)
    vm = create_vm(vm_host: create_vm_host, boot_image: "github-ubuntu-2204")
    Sshable.create_with_id(vm)
    described_class.create(repository_name: "test-repo", label: "ubicloud", vm_id: vm.id, location_id: vm.location_id, installation_id: ins.id)
  }

  def clog_emit_hash
    hash = nil
    message = "runner_tested"
    expect(Clog).to(receive(:emit).with(message, instance_of(Hash)).and_wrap_original do |original_method, *args, b|
      hash = b
      original_method.call(*args, hash)
    end)
    github_runner.log_duration(message, 10)
    hash[message]
  end

  it "can log duration with a vm" do
    vm = github_runner.vm
    boot_image = BootImage.create(vm_host_id: vm.vm_host_id, name: "github-ubuntu-2204", version: "20251211", size_gib: 75)
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 75, disk_index: 0, boot_image_id: boot_image.id)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: boot_image.version,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
    })
  end

  it "can log duration with ch_version if the vm's strand has one" do
    vm = github_runner.vm
    Strand.create(prog: "Vm::Metal::Nexus", label: "start", stack: [{"ch_version" => "53.0"}]) { it.id = vm.id }
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: vm.boot_image,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
      ch_version: "53.0",
    })
  end

  it "can log duration when it's from a vm pool" do
    pool = VmPool.create(size: 1, vm_size: "standard-2", location_id: Location::HETZNER_FSN1_ID, boot_image: "github-ubuntu-2204", storage_size_gib: 86)
    vm = github_runner.vm
    vm.update(pool_id: pool.id)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: vm.boot_image,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
      vm_pool_ubid: pool.ubid,
    })
  end

  it "can log duration with vhost block backend version" do
    vm = github_runner.vm
    vhost_block_backend = create_vhost_block_backend(vm_host_id: vm.vm_host_id)
    boot_image = BootImage.create(vm_host_id: vm.vm_host_id, name: "github-ubuntu-2204", version: "20251211", size_gib: 75)
    VmStorageVolume.create(
      vm_id: vm.id,
      boot: true,
      size_gib: 75,
      disk_index: 0,
      boot_image_id: boot_image.id,
      vhost_block_backend_id: vhost_block_backend.id,
      vring_workers: 4,
    )

    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: boot_image.version,
      vhost_block_backend_version: vhost_block_backend.version,
      cores: vm.cores,
      vcpus: vm.vcpus,
      vm_host_ubid: vm.vm_host.ubid,
      data_center: vm.vm_host.data_center,
    })
  end

  it "can log duration when vm does not have vm_host" do
    github_runner.vm.update(vm_host_id: nil)
    vm = github_runner.vm
    AwsInstance.create_with_id(vm.id, instance_id: "i-0123456789abcdefg")
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      instance_id: "i-0123456789abcdefg",
      conclusion: nil,
      vm_ubid: vm.ubid,
      arch: vm.arch,
      boot_image: vm.boot_image,
      cores: vm.cores,
      vcpus: vm.vcpus,
    })
  end

  it "can log duration without a vm" do
    github_runner.update(vm_id: nil, location_id: nil)
    expect(clog_emit_hash).to eq({
      repository_name: "test-repo",
      ubid: github_runner.ubid,
      label: github_runner.label,
      duration: 10,
      conclusion: nil,
    })
  end

  it "provisions a spare runner and increments the spare_runner_provisioned semaphore" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")

    spare_runner = github_runner.provision_spare_runner

    expect(spare_runner).to be_a(described_class)
    expect(spare_runner.installation_id).to eq(github_runner.installation_id)
    expect(spare_runner.repository_name).to eq(github_runner.repository_name)
    expect(spare_runner.label).to eq(github_runner.label)
    expect(github_runner.spare_runner_provisioned_set?(cached: false)).to be(true)
  end

  it "does not provision another spare runner once one has been provisioned" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.incr_spare_runner_provisioned

    expect {
      expect(github_runner.provision_spare_runner).to be_nil
    }.not_to change(described_class, :count)
  end

  it "does not provision a spare runner if the project has hit spending cutoff" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.project.update(cutoff_at: Time.now)

    expect {
      expect(github_runner.provision_spare_runner).to be_nil
    }.not_to change(described_class, :count)
    expect(github_runner.spare_runner_provisioned_set?(cached: false)).to be(false)
  end

  it "provisions a spare runner when force is true even if the project has hit spending cutoff" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.project.update(cutoff_at: Time.now)

    expect {
      expect(github_runner.provision_spare_runner(force: true)).to be_a(described_class)
    }.to change(described_class, :count).from(1).to(2)
    expect(github_runner.spare_runner_provisioned_set?(cached: false)).to be(true)
  end

  it "provisions a spare runner regardless of the semaphore when force is true" do
    Strand.create_with_id(github_runner, prog: "Github::GithubRunnerNexus", label: "start")
    github_runner.incr_spare_runner_provisioned

    expect {
      expect(github_runner.provision_spare_runner(force: true)).to be_a(described_class)
    }.to change(described_class, :count).from(1).to(2)
  end

  describe "#destroy" do
    def deleted_records
      DeletedRecord.where(model_name: "GithubRunner", record_id: github_runner.id)
    end

    it "does not create a DeletedRecord is skip_deleted_record is set" do
      github_runner.skip_deleted_record!
      github_runner.destroy
      expect(deleted_records.count).to eq(0)
    end

    it "creates a DeletedRecord by default" do
      github_runner.destroy
      expect(deleted_records.count).to eq(1)
    end
  end

  describe "#workflow_run_create_date" do
    let(:today) { Time.now.utc.to_date }
    let(:repository) { GithubRepository.create(installation_id: github_runner.installation_id, name: "test-repo") }

    before do
      github_runner.update(repository_id: repository.id, run_id: 456, run_attempt: 2)
    end

    def create_active_run(create_date)
      GithubActiveWorkflowRun.create(installation_id: github_runner.installation_id, repository_id: repository.id, create_date:, repository_name: "test-repo", run_id: 456, run_attempt: 2, head_branch: "main", head_repository_full_name: "test-repo", event: "push", status: "in_progress", display_title: "CI", commit_message: "cm", actor_login: "al", cache_scope: "main")
    end

    def create_completed_run(create_date, run_attempt: 2)
      GithubCompletedWorkflowRun.create_partition(create_date) unless GithubCompletedWorkflowRun.partition_days.include?(create_date)
      GithubCompletedWorkflowRun.insert(repository_id: repository.id, run_id: 456, run_attempt:, create_date:, installation_id: github_runner.installation_id, created_at: Time.now, run_started_at: Time.now, completed_at: Time.now, event: "push", status: "completed", conclusion: "success", display_title: "CI", actor_login: "al", duration: 90)
    end

    it "returns nil if there is no active or completed workflow run" do
      create_completed_run(today, run_attempt: 1)
      expect(github_runner.workflow_run_create_date).to be_nil
    end

    it "returns the create date of the active workflow run, preferring it to a completed workflow run" do
      create_active_run(today - 30)
      create_completed_run(today)
      expect(github_runner.workflow_run_create_date).to eq(today - 30)
    end

    it "returns the create date of a completed workflow run created in the last 7 days" do
      create_completed_run(today - 5)
      expect(github_runner.workflow_run_create_date).to eq(today - 5)
    end

    it "returns nil if the completed workflow run was created more than 7 days ago" do
      create_completed_run(today - 8)
      expect(github_runner.workflow_run_create_date).to be_nil
    end
  end

  describe "workflow job info accessors" do
    let(:columns) { [:job_id, :run_id, :head_branch, :workflow_name, :job_name, :job_created_at, :job_started_at, :job_completed_at, :status, :conclusion] }

    it "returns nil when neither the column nor workflow_job is set" do
      expect(github_runner.workflow_job).to be_nil
      expect(columns.map { github_runner.send(it) }).to all(be_nil)
      expect(github_runner.has_workflow_job_info?).to be false
    end

    it "falls back to workflow_job when the column is not set" do
      github_runner.update(workflow_job: {"id" => 1, "run_id" => 2, "head_branch" => "main", "workflow_name" => "CI", "name" => "test", "created_at" => "2026-09-01T10:00:00Z", "started_at" => "2026-09-01T10:01:00Z", "completed_at" => "2026-09-01T10:05:00Z", "status" => "completed", "conclusion" => "success"})
      expect(github_runner.has_workflow_job_info?).to be true
      expect(columns.map { github_runner.send(it) }).to eq([1, 2, "main", "CI", "test", Time.utc(2026, 9, 1, 10), Time.utc(2026, 9, 1, 10, 1), Time.utc(2026, 9, 1, 10, 5), "completed", "success"])
    end

    it "prefers the column over workflow_job" do
      github_runner.update(job_id: 10, run_id: 20, head_branch: "dev", workflow_name: "Build", job_name: "lint", job_created_at: Time.utc(2026, 9, 2, 10), job_started_at: Time.utc(2026, 9, 2, 10, 1), job_completed_at: Time.utc(2026, 9, 2, 10, 4), status: "in_progress", conclusion: "failure", workflow_job: {"id" => 1, "run_id" => 2, "head_branch" => "main", "workflow_name" => "CI", "name" => "test", "created_at" => "2026-09-01T10:00:00Z", "started_at" => "2026-09-01T10:01:00Z", "completed_at" => "2026-09-01T10:05:00Z", "status" => "completed", "conclusion" => "success"})
      github_runner.refresh
      expect(columns.map { github_runner.send(it) }).to eq([10, 20, "dev", "Build", "lint", Time.utc(2026, 9, 2, 10), Time.utc(2026, 9, 2, 10, 1), Time.utc(2026, 9, 2, 10, 4), "in_progress", "failure"])
    end
  end

  describe ".alien_metrics_targets" do
    def create_runner(location_id, installation, ready_at: Time.now)
      described_class.create(repository_name: "repo", label: "ubicloud", vm_id: create_vm(location_id:).id, location_id:, installation_id: installation.id, ready_at:)
    end

    it "returns the ready AWS and GCP runners of projects with runner metrics" do
      provider_project_id = Project.create(name: "providers").id
      aws_location = Location.create(name: "eu-central-1", provider: "aws", project_id: provider_project_id, display_name: "aws-eu-central-1", ui_name: "AWS Frankfurt", visible: true)
      gcp_location = Location.create(name: "gcp-europe-west3", provider: "gcp", project_id: provider_project_id, display_name: "gcp-europe-west3", ui_name: "GCP Frankfurt", visible: false)
      expect(Config).to receive(:github_runner_aws_location_id).and_return(aws_location.id)
      expect(Config).to receive(:github_runner_gcp_location_id).and_return(gcp_location.id)
      metrics_project = Project.create(name: "metrics")
      metrics_project.set_ff_github_runner_metrics(true)
      metrics_installation = GithubInstallation.create(installation_id: 1, name: "metrics", type: "User", project_id: metrics_project.id)
      other_installation = GithubInstallation.create(installation_id: 2, name: "other", type: "User", project_id: Project.create(name: "other").id)
      aws_target = create_runner(aws_location.id, metrics_installation)
      gcp_target = create_runner(gcp_location.id, metrics_installation)
      create_runner(aws_location.id, metrics_installation, ready_at: nil)
      create_runner(Location::HETZNER_FSN1_ID, metrics_installation)
      create_runner(aws_location.id, other_installation)

      expect(described_class.alien_metrics_targets.select_order_map(:id)).to eq([aws_target.id, gcp_target.id].sort)
    end
  end

  describe "metrics export" do
    let(:ssh_session) { Net::SSH::Connection::Session.allocate }
    let(:tsdb_client) { VictoriaMetrics::Client.new(endpoint: "http://victoria-metrics.test") }
    let(:read_command) { %q(tr -d '\0' < /run/ubicloud-metrics/ring | awk -F '[:,]' -v last=2 '/^\{"seq":/ && $2 > last { sub(/ +$/, ""); print }') }

    def line(seq, time)
      metrics = RunnerMetricsEntry::METRICS.to_h { |metric| [metric, (metric == "runner_queue_ldavg_1") ? 0.5 : 0] }
      JSON.generate({"seq" => seq, "time" => time}.merge(metrics))
    end

    it "exports to the runner metrics project" do
      project_id = Project.generate_uuid
      expect(Config).to receive(:github_runner_metrics_project_id).and_return(project_id)

      expect(github_runner.metrics_config).to eq({project_id:})
    end

    it "starts a session reading the ring from its first seq" do
      expect(github_runner.vm.sshable).to receive(:start_fresh_session).and_return(ssh_session)

      expect(github_runner.init_metrics_export_session).to eq({ssh_session:, last_seq: 0})
    end

    it "imports the ring's new samples and remembers the newest seq" do
      now = Time.at(Time.now.to_i)
      now_ms = now.to_i * 1000
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      expect(ssh_session).to receive(:_exec!).with(read_command).and_return("#{line(3, now.to_i)}\n")
      labels = "ubicloud_resource_id=\"#{github_runner.ubid}\",vm=\"#{github_runner.vm.ubid}\""
      samples = RunnerMetricsEntry::METRICS.map { |metric| "#{metric}{#{labels}} #{(metric == "runner_queue_ldavg_1") ? 0.5 : 0} #{now_ms}\n" }.join
      import = stub_request(:post, "http://victoria-metrics.test/api/v1/import/prometheus?timestamp=#{now_ms}")
        .with { Zlib.gunzip(it.body) == samples }
        .to_return(status: 204)
      session = {ssh_session:, last_seq: 2}

      github_runner.export_metrics(session:, tsdb_client:)
      expect(import).to have_been_requested
      expect(session[:last_seq]).to eq(3)
    end

    it "keeps the seq when the ring has no new samples" do
      expect(ssh_session).to receive(:_exec!).with(read_command).and_return("")
      session = {ssh_session:, last_seq: 2}

      github_runner.export_metrics(session:, tsdb_client:)
      expect(session[:last_seq]).to eq(2)
    end

    it "stops collecting from a runner whose ring has invalid data" do
      expect(ssh_session).to receive(:_exec!).with(read_command).and_return("{\"seq\":3}\n")
      expect(Clog).to receive(:emit).with("Stopped collecting runner metrics", {runner_metrics_invalid: {ubid: github_runner.ubid, reason: "ring line does not have the expected keys"}}).and_call_original
      session = {ssh_session:, last_seq: 2}

      github_runner.export_metrics(session:, tsdb_client:)
      expect(session).to eq({ssh_session:, last_seq: 2, invalid: true})
      expect(github_runner.export_metrics(session:, tsdb_client:)).to be_nil
    end
  end
end
