# frozen_string_literal: true

require "octokit"
require "yaml"

class Prog::Test::GithubRunner < Prog::Test::Base
  FAIL_CONCLUSIONS = ["action_required", "cancelled", "failure", "skipped", "stale", "timed_out"]
  IN_PROGRESS_CONCLUSIONS = ["in_progress", "queued", "requested", "waiting", "pending", "neutral"]

  def self.assemble(vm_host_id, test_cases)
    github_service_project = Project.create(name: "Github Runner Service Project") { _1.id = Config.github_runner_service_project_id }
    github_service_project.associate_with_project(github_service_project)

    github_test_project = Project.create_with_id(name: "Github Runner Test Project")
    github_test_project.associate_with_project(github_test_project)
    GithubInstallation.create_with_id(
      installation_id: Config.e2e_github_installation_id,
      name: "TestUser",
      type: "User",
      project_id: github_test_project.id
    )

    Strand.create_with_id(
      prog: "Test::GithubRunner",
      label: "start",
      stack: [{
        "created_at" => Time.now.utc,
        "vm_host_id" => vm_host_id,
        "test_cases" => test_cases,
        "github_service_project_id" => github_service_project.id,
        "github_test_project_id" => github_test_project.id
      }]
    )
  end

  label def start
    hop_download_boot_images
  end

  label def download_boot_images
    frame["test_cases"].each do |test_case|
      bud Prog::DownloadBootImage, {"subject_id" => vm_host_id, "image_name" => tests[test_case]["image_name"]}
    end

    hop_wait_download_boot_images
  end

  label def wait_download_boot_images
    reap
    hop_trigger_test_runs if leaf?
    donate
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

    nap 15 if GithubRunner.any?

    GithubRepository.each { _1.destroy }
    Project[frame["github_service_project_id"]]&.destroy
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
    client.workflow_dispatch(repo_name, workflow_name, branch_name)
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

  def tests
    @tests ||= YAML.load_file("config/github_runner_e2e_tests.yml").to_h { [_1["name"], _1] }
  end

  def test_runs
    @test_runs ||= frame["test_cases"].flat_map { tests[_1]["runs"] }
  end

  def vm_host_id
    @vm_host_id ||= frame["vm_host_id"] || VmHost.first.id
  end

  def client
    @client ||= Github.installation_client(Config.e2e_github_installation_id)
  end
end
