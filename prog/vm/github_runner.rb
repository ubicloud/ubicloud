# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::GithubRunner < Prog::Base
  subject_is :github_runner

  semaphore :destroy

  def self.assemble(installation, repository_name:, label:)
    unless Github.runner_labels[label]
      fail "Invalid GitHub runner label: #{label}"
    end

    DB.transaction do
      github_runner = GithubRunner.create_with_id(
        installation_id: installation.id,
        repository_name: repository_name,
        label: label
      )

      Strand.create(prog: "Vm::GithubRunner", label: "start") { _1.id = github_runner.id }
    end
  end

  def pick_vm
    label = github_runner.label
    label_data = Github.runner_labels[label]
    pool = VmPool.where(
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location: label_data["location"],
      storage_size_gib: label_data["storage_size_gib"],
      storage_encrypted: false,
      storage_skip_sync: false,
      arch: label_data["arch"]
    ).first

    if (picked_vm = pool&.pick_vm)
      Clog.emit("Pool is used") { {github_runner: {label: github_runner.label, repository_name: github_runner.repository_name, cores: picked_vm.cores}} }
      return picked_vm
    end

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "runner",
      Config.github_runner_service_project_id,
      name: github_runner.ubid.to_s,
      size: label_data["vm_size"],
      location: label_data["location"],
      boot_image: label_data["boot_image"],
      storage_volumes: [{size_gib: label_data["storage_size_gib"], encrypted: false}],
      enable_ip4: true,
      arch: label_data["arch"],
      allow_only_ssh: true
    )

    Clog.emit("Pool is empty") { {github_runner: {label: github_runner.label, repository_name: github_runner.repository_name, cores: vm_st.subject.cores}} }
    vm_st.subject
  end

  def update_billing_record
    # If the runner is destroyed before it's ready or doesn't pick a job, don't charge for it.
    return unless github_runner.ready_at && github_runner.workflow_job

    project = github_runner.installation.project
    label_data = Github.runner_labels[github_runner.label]
    rate_id = if label_data["arch"] == "arm64"
      BillingRate.from_resource_properties("GitHubRunnerMinutes", "#{label_data["vm_size"]}-arm", "global")["id"]
    else
      BillingRate.from_resource_properties("GitHubRunnerMinutes", label_data["vm_size"], "global")["id"]
    end

    retries = 0
    begin
      begin_time = Time.now.to_date.to_time
      end_time = begin_time + 24 * 60 * 60
      used_amount = ((Time.now - github_runner.ready_at) / 60).ceil
      today_record = BillingRecord
        .where(project_id: project.id, resource_id: project.id, billing_rate_id: rate_id)
        .where { Sequel.pg_range(_1.span).overlaps(Sequel.pg_range(begin_time...end_time)) }
        .first

      if today_record
        today_record.amount = Sequel[:amount] + used_amount
        today_record.save_changes(validate: false)
      else
        BillingRecord.create_with_id(
          project_id: project.id,
          resource_id: project.id,
          resource_name: "Daily Usage #{begin_time.strftime("%Y-%m-%d")}",
          billing_rate_id: rate_id,
          span: Sequel.pg_range(begin_time...end_time),
          amount: used_amount
        )
      end
    rescue Sequel::Postgres::ExclusionConstraintViolation
      # The billing record has an exclusion constraint, which prevents the
      # creation of multiple billing records for the same day. If a thread
      # encounters this constraint, it immediately retries 4 times.
      retries += 1
      retry unless retries > 4
      raise
    end
  end

  SERVICE_NAME = "runner-script"

  def vm
    @vm ||= github_runner.vm
  end

  def github_client
    @github_client ||= Github.installation_client(github_runner.installation.installation_id)
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_vm_destroy"].include?(strand.label)
        register_deadline(nil, 10 * 60)
        update_billing_record
        hop_destroy
      end
    end
  end

  label def start
    picked_vm = pick_vm
    github_runner.update(vm_id: picked_vm.id)
    picked_vm.update(name: github_runner.ubid.to_s)
    hop_wait_vm
  end

  label def wait_vm
    nap 5 unless vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    hop_setup_environment
  end

  def setup_info
    {
      group: "Ubicloud Managed Runner",
      detail: {
        "Name" => github_runner.ubid,
        "Label" => github_runner.label,
        "Arch" => vm.arch,
        "Image" => vm.boot_image,
        "VM Host" => vm.vm_host.ubid,
        "VM Pool" => vm.pool_id ? UBID.from_uuidish(vm.pool_id).to_s : nil,
        "Location" => vm.vm_host.location,
        "Datacenter" => vm.vm_host.data_center,
        "Project" => github_runner.installation.project.ubid,
        "Console URL" => "https://console.ubicloud.com#{github_runner.installation.project.path}/github"
      }.map { "#{_1}: #{_2}" }.join("\n")
    }
  end

  label def setup_environment
    command = <<~COMMAND
      # runner unix user needed access to manipulate the Docker daemon.
      # Default GitHub hosted runners have additional adm,systemd-journal groups.
      sudo usermod -a -G docker,adm,systemd-journal runner

      # Some configuration files such as $PATH related to the user's home directory
      # need to be changed. GitHub recommends to run post-generation scripts after
      # initial boot.
      # The important point, scripts use latest record at /etc/passwd as default user.
      # So we need to run these scripts before bootstrap_rhizome to use runner user,
      # instead of rhizome user.
      # https://github.com/actions/runner-images/blob/main/docs/create-image-and-azure-resources.md#post-generation-scripts
      sudo su -c "find /opt/post-generation -mindepth 1 -maxdepth 1 -type f -name '*.sh' -exec bash {} ';'"

      # Post-generation scripts write some variables at /etc/environment file.
      # We need to reload environment variables again.
      source /etc/environment

      # We placed the script in the "/usr/local/share/" directory while generating
      # the golden image. However, it needs to be moved to the home directory because
      # the runner creates some configuration files at the script location. The "runner"
      # user doesn't have write permission for the "/usr/local/share/" directory.
      sudo [ ! -d /usr/local/share/actions-runner ] || sudo mv /usr/local/share/actions-runner ./
      sudo chown -R runner:runner actions-runner

      # ./env.sh sets some variables for runner to run properly
      ./actions-runner/env.sh

      # Include /etc/environment in the runner environment, it's
      # otherwise ignored, and this omission has caused problems.
      # See https://github.com/actions/runner/issues/1703
      cat <<EOT > ./actions-runner/run-withenv.sh
      #!/bin/bash
      mapfile -t env </etc/environment
      exec env -- "\\${env[@]}" ./actions-runner/run.sh --jitconfig "\\$1"
      EOT
      chmod +x ./actions-runner/run-withenv.sh

      # runner script doesn't use global $PATH variable by default. It gets path from
      # secure_path at /etc/sudoers. Also script load .env file, so we are able to
      # overwrite default path value of runner script with $PATH.
      # https://github.com/microsoft/azure-pipelines-agent/issues/3461
      echo "PATH=$PATH" >> ./actions-runner/.env

      # The `imagedata.json` file contains information about the generated image.
      # I enrich it with details about the Ubicloud environment and placed it in the runner's home directory.
      # GitHub-hosted runners also use this file as setup_info to show on the GitHub UI.
      cat /imagegeneration/imagedata.json | jq '. += [#{setup_info.to_json}]' > /home/runner/actions-runner/.setup_info
    COMMAND

    # Remove comments and empty lines before sending them to the machine
    vm.sshable.cmd(command.gsub(/^(# .*)?\n/, ""))

    hop_register_runner
  end

  label def register_runner
    # We use generate-jitconfig instead of registration-token because it's
    # recommended by GitHub for security reasons.
    # https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-just-in-time-runners
    data = {name: github_runner.ubid.to_s, labels: [github_runner.label], runner_group_id: 1, work_folder: "/home/runner/work"}
    response = github_client.post("/repos/#{github_runner.repository_name}/actions/runners/generate-jitconfig", data)
    github_runner.update(runner_id: response[:runner][:id], ready_at: Time.now)

    # We initiate an API call and a SSH connection under the same label to avoid
    # having to store the encoded_jit_config.
    vm.sshable.cmd("sudo -- xargs -I{} -- systemd-run --uid runner --gid runner " \
                   "--working-directory '/home/runner' --unit #{SERVICE_NAME} --remain-after-exit -- " \
                   "./actions-runner/run-withenv.sh {}",
      stdin: response[:encoded_jit_config])

    hop_wait
  rescue Octokit::Conflict => e
    unless e.message.include?("Already exists")
      raise e
    end
    # If the runner already exists at GitHub side, this suggests that the
    # process terminated prematurely before start the runner script and hop wait.
    # We need to locate the 'runner_id' using the name and delete it.
    # After this, we can register the runner again.
    runners = github_client.paginate("/repos/#{github_runner.repository_name}/actions/runners") do |data, last_response|
      data[:runners].concat last_response.data[:runners]
    end
    unless (runner = runners[:runners].find { _1[:name] == github_runner.ubid.to_s })
      fail "BUG: Failed with runner already exists error but couldn't find it"
    end
    Clog.emit("Deleting GithubRunner because it already exists") { {github_runner: github_runner.values.merge({runner_id: runner[:id]})} }
    github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{runner[:id]}")
    nap 5
  end

  label def wait
    case vm.sshable.cmd("systemctl show -p SubState --value #{SERVICE_NAME}").chomp
    when "exited"
      github_runner.incr_destroy
      nap 0
    when "failed"
      github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      github_runner.update(runner_id: nil, ready_at: nil)
      hop_register_runner
    end

    # If the runner doesn't pick a job within five minutes, the job may have
    # been cancelled prior to assignment, so we destroy the runner. But we also
    # check if the runner is busy or not with GitHub API.
    if github_runner.workflow_job.nil? && Time.now > github_runner.ready_at + 5 * 60
      response = github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      unless response[:busy]
        github_runner.incr_destroy
        Clog.emit("The runner does not pick a job") { {github_runner: github_runner.values} }
        nap 0
      end
    end

    nap 15
  end

  label def destroy
    decr_destroy

    # Waiting 404 Not Found response for get runner request
    begin
      github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      nap 5
    rescue Octokit::NotFound
    end

    if vm
      vm.private_subnets.each { _1.incr_destroy }
      vm.incr_destroy
    end

    hop_wait_vm_destroy
  end

  label def wait_vm_destroy
    nap 10 unless vm.nil?

    github_runner.destroy
    pop "github runner deleted"
  end
end
