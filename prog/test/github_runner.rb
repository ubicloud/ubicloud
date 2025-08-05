# frozen_string_literal: true

require "octokit"
require "yaml"

class Prog::Test::GithubRunner < Prog::Test::Base
  FAIL_CONCLUSIONS = ["action_required", "cancelled", "failure", "skipped", "stale", "timed_out"]
  IN_PROGRESS_CONCLUSIONS = ["in_progress", "queued", "requested", "waiting", "pending", "neutral"]

  def self.assemble(test_cases)
    github_service_project = Project.create_with_id(Config.github_runner_service_project_id, name: "Github-Runner-Service-Project")

    vm_pool_service_project = Project.create_with_id(Config.vm_pool_project_id, name: "Vm-Pool-Service-Project")

    github_test_project = Project.create(name: "Github-Runner-Test-Project")
    GithubInstallation.create(
      installation_id: Config.e2e_github_installation_id,
      name: "TestUser",
      type: "User",
      project_id: github_test_project.id,
      created_at: Time.now - 8 * 24 * 60 * 60
    )

    Strand.create(
      prog: "Test::GithubRunner",
      label: "start",
      stack: [{
        "created_at" => Time.now.utc,
        "test_cases" => test_cases,
        "github_service_project_id" => github_service_project.id,
        "vm_pool_service_project" => vm_pool_service_project.id,
        "github_test_project_id" => github_test_project.id
      }]
    )
  end

  label def start
    hop_create_vm_pool
  end

  label def create_vm_pool
    label_data = Github.runner_labels["ubicloud"]
    pool = Prog::Vm::VmPool.assemble(
      size: 1,
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location_id: Location::GITHUB_RUNNERS_ID,
      storage_size_gib: label_data["storage_size_gib"],
      arch: label_data["arch"],
      storage_encrypted: true,
      storage_skip_sync: true
    ).subject
    update_stack({"vm_pool_id" => pool.id})

    hop_wait_vm_pool_to_be_ready
  end

  label def wait_vm_pool_to_be_ready
    pool = VmPool[frame["vm_pool_id"]]
    nap 10 unless pool.size == pool.vms_dataset.exclude(provisioned_at: nil).count

    # No need to provision a new VM to the pool when the first one is picked.
    # This simplifies the process of verifying at the end of the test that VMs
    # were correctly picked from the pool.
    pool.update(size: 0)
    hop_trigger_test_runs
  end

  label def trigger_test_runs
    test_runs.each do |test_run|
      unless trigger_test_run(test_run["repo_name"], test_run["workflow_name"], test_run["branch_name"])
        update_stack({"fail_message" => "Can not trigger workflow for #{test_run["repo_name"]}, #{test_run["workflow_name"]}, #{test_run["branch_name"]}"})
        hop_clean_resources
      end
    end

    # To make sure that test runs are triggered
    # We sill still check the runs in the next step in
    # case an incident happens on the github side
    sleep 30

    hop_check_test_runs
  end

  label def check_test_runs
    test_runs.each do |test_run|
      latest_run = latest_run(test_run["repo_name"], test_run["workflow_name"], test_run["branch_name"])

      # In case the run can not be triggered in the previous state
      if latest_run[:created_at] < Time.parse(frame["created_at"])
        update_stack({"fail_message" => "Can not trigger workflow for #{test_run["repo_name"]}, #{test_run["workflow_name"]}, #{test_run["branch_name"]}"})
        break
      end

      conclusion = latest_run[:conclusion]
      if FAIL_CONCLUSIONS.include?(conclusion)
        update_stack({"fail_message" => "Test run for #{test_run["repo_name"]}, #{test_run["workflow_name"]}, #{test_run["branch_name"]} failed with conclusion #{conclusion}"})
        break
      elsif IN_PROGRESS_CONCLUSIONS.include?(conclusion) || conclusion.nil?
        nap 15
      end
    end

    hop_clean_resources
  end

  label def clean_resources
    cancel_test_runs

    if GithubRunner.any?
      Clog.emit("Waiting runners to finish their jobs")
      nap 15
    end

    if (pool = VmPool[frame["vm_pool_id"]])
      unless pool.vms.count.zero?
        update_stack({"fail_message" => "The runner did not picked from the pool"})
      end
      pool.incr_destroy
    end
    GithubRepository.each(&:incr_destroy)

    if VmPool.any?
      Clog.emit("Waiting vm pools to be destroyed")
      nap 15
    end

    if GithubRepository.any?
      Clog.emit("Waiting repositories to be destroyed")
      nap 15
    end

    Project[frame["github_service_project_id"]]&.destroy
    Project[frame["vm_pool_service_project"]]&.destroy
    Project[frame["github_test_project_id"]]&.destroy

    frame["fail_message"] ? fail_test(frame["fail_message"]) : hop_finish
  end

  label def finish
    pop "GithubRunner tests are finished!"
  end

  label def failed
    nap 15
  end

  def trigger_test_run(repo_name, workflow_name, branch_name)
    client.workflow_dispatch(repo_name, workflow_name, branch_name, {inputs: {triggered_by: ENV["GITHUB_RUN_ID"]}})
  end

  def latest_run(repo_name, workflow_name, branch_name)
    runs = client.workflow_runs(repo_name, workflow_name, {branch: branch_name})
    runs[:workflow_runs].first
  end

  def cancel_test_runs
    test_runs.each do |test_run|
      cancel_test_run(test_run["repo_name"], test_run["workflow_name"], test_run["branch_name"])
    end
  end

  def cancel_test_run(repo_name, workflow_name, branch_name)
    run_id = latest_run(repo_name, workflow_name, branch_name)[:id]
    begin
      client.cancel_workflow_run(repo_name, run_id)
    rescue
      Clog.emit("Workflow run #{run_id} for #{repo_name} has already been finished")
    end
  end

  def test_runs
    @test_runs ||= frame["test_cases"].map { it["details"] }
  end

  def client
    @client ||= Github.installation_client(Config.e2e_github_installation_id)
  end
end
