# frozen_string_literal: true

require "octokit"
require "yaml"

class Prog::Test::GithubRunner < Prog::Test::Base
  FAIL_CONCLUSIONS = %w[action_required cancelled failure skipped stale timed_out].freeze
  IN_PROGRESS_CONCLUSIONS = %w[in_progress queued requested waiting pending neutral].freeze
  REPOSITORY_NAME_PREFIX = "tahcloud/github-e2e-tests"
  WORKFLOW_NAME = "test.yml"
  BRANCH_NAME = "enes/simply-tests"

  def self.assemble(test_cases, provider: "metal")
    service_project = Project.create_with_id(Config.github_runner_service_project_id, name: "Github-Runner-Service-Project")
    Project.create_with_id(Config.vm_pool_project_id, name: "Vm-Pool-Service-Project")
    customer_project = Project.create(name: "Github-Runner-Customer-Project")

    if provider == "aws"
      customer_project.set_ff_aws_alien_runners_ratio(1)
      location = Location.create_with_id(Config.github_runner_aws_location_id, name: "eu-central-1", provider: "aws", project_id: service_project.id, display_name: "aws-e2e", ui_name: "aws-e2e", visible: true)
      LocationCredential.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
    end

    if (url = Config.e2e_cache_proxy_download_url) && !url.empty?
      customer_project.set_ff_cache_proxy_download_url({x64: url})
    end

    GithubInstallation.create(
      installation_id: Config.e2e_github_installation_id,
      name: "TestUser",
      type: "User",
      project_id: customer_project.id,
      created_at: Time.now - 8 * 24 * 60 * 60
    )

    labels = []
    labels << "ubicloud-standard-2-ubuntu-2204" if test_cases.any? { it["name"].include?("2204") }
    labels << "ubicloud-standard-2-ubuntu-2404" if test_cases.any? { it["name"].include?("2404") }

    Strand.create(
      prog: "Test::GithubRunner",
      label: "start",
      stack: [{
        "created_at" => Time.now.utc,
        "provider" => provider,
        "customer_project_id" => customer_project.id,
        "labels" => labels
      }]
    )
  end

  label def start
    hop_trigger_test_run if frame["provider"] == "aws"
    hop_create_vm_pool
  end

  label def create_vm_pool
    label_data = Github.runner_labels[frame["labels"].first]
    pool = Prog::Vm::VmPool.assemble(
      size: 2,
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location_id: Location::GITHUB_RUNNERS_ID,
      storage_size_gib: label_data["storage_size_gib"],
      arch: label_data["arch"],
      storage_encrypted: true
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
    hop_trigger_test_run
  end

  label def trigger_test_run
    inputs = {triggered_by: ENV["GITHUB_RUN_ID"], provider: frame["provider"], runners: frame["labels"].to_json}
    unless client.post("repos/#{repository_name}/actions/workflows/#{WORKFLOW_NAME}/dispatches", {ref: BRANCH_NAME, inputs:})
      update_stack({"fail_message" => "Couldn't trigger workflow"})
      hop_clean_resources
    end

    # To make sure that test runs are triggered
    # We sill still check the runs in the next step in
    # case an incident happens on the github side
    sleep 30

    hop_check_test_run
  end

  label def check_test_run
    runs = client.workflow_runs(repository_name, WORKFLOW_NAME, {branch: BRANCH_NAME})[:workflow_runs]
    run = runs.find { it[:created_at] >= Time.parse(frame["created_at"]) && it[:name].include?(ENV["GITHUB_RUN_ID"]) }
    if run
      update_stack({"test_run_id" => run[:id]})
      conclusion = run[:conclusion]
      if FAIL_CONCLUSIONS.include?(conclusion)
        update_stack({"fail_message" => "Test run failed with conclusion: #{conclusion}"})
      elsif IN_PROGRESS_CONCLUSIONS.include?(conclusion) || conclusion.nil?
        nap 15
      end
    else
      update_stack({"fail_message" => "Couldn't find the triggered workflow run"})
    end

    hop_clean_resources
  end

  label def clean_resources
    begin
      client.cancel_workflow_run(repository_name, frame["test_run_id"]) if frame["test_run_id"]
    rescue Octokit::Error
      Clog.emit("Workflow run #{frame["test_run_id"]} has already been finished")
    end

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

    Project[Config.github_runner_service_project_id]&.destroy
    Project[Config.vm_pool_project_id]&.destroy
    Project[frame["customer_project_id"]]&.destroy

    frame["fail_message"] ? fail_test(frame["fail_message"]) : hop_finish
  end

  label def finish
    pop "GithubRunner tests are finished!"
  end

  label def failed
    nap 15
  end

  def repository_name
    "#{REPOSITORY_NAME_PREFIX}-#{frame["provider"]}"
  end

  def client
    @client ||= Github.installation_client(Config.e2e_github_installation_id, auto_paginate: true)
  end
end
