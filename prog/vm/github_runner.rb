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
    skip_sync = true
    pool = VmPool.where(
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location: label_data["location"],
      storage_size_gib: label_data["storage_size_gib"],
      storage_encrypted: false,
      storage_skip_sync: skip_sync,
      arch: label_data["arch"]
    ).first

    if (picked_vm = pool&.pick_vm)
      Clog.emit("Pool is used") { {github_runner: {label: github_runner.label, repository_name: github_runner.repository_name, cores: picked_vm.cores}} }
      return picked_vm
    end

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "runneradmin",
      Config.github_runner_service_project_id,
      name: github_runner.ubid.to_s,
      size: label_data["vm_size"],
      location: label_data["location"],
      boot_image: label_data["boot_image"],
      storage_volumes: [{size_gib: label_data["storage_size_gib"], encrypted: false, skip_sync: skip_sync}],
      enable_ip4: true,
      arch: label_data["arch"],
      allow_only_ssh: true,
      swap_size_bytes: 4294963200 # ~4096MB, the same value with GitHub hosted runners
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
    hop_wait_concurrency_limit unless concurrency_available?
    hop_allocate_vm
  end

  label def wait_concurrency_limit
    hop_allocate_vm if concurrency_available?

    # check utilization, if it's high, wait for it to go down
    utilization = VmHost.where(location: "github-runners", allocation_state: "accepting", arch: github_runner.label.include?("arm") ? "arm64" : "x64").select_map {
      sum(:used_cores) * 100.0 / sum(:total_cores)
    }.first.to_f

    unless utilization < 60
      Clog.emit("Waiting for customer concurrency limit, utilization is high") { {github_runner: github_runner.values, utilization: utilization} }
      nap 5
    end

    Clog.emit("Concurrency limit reached but allocation is allowed because of low utilization") { {github_runner: github_runner.values, utilization: utilization} }

    hop_allocate_vm
  end

  label def allocate_vm
    picked_vm = pick_vm
    github_runner.update(vm_id: picked_vm.id)
    picked_vm.update(name: github_runner.ubid.to_s)

    hop_wait_vm
  end

  label def wait_vm
    nap 5 unless vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    hop_create_runner_user
  end

  label def create_runner_user
    # Sending addgroup and adduser separately, as there is no way
    # to force group and user has specific names and ids with a
    # single command
    command = <<~COMMAND
      set -ueo pipefail
      sudo userdel -rf runner || true
      sudo addgroup --gid 1001 runner
      sudo adduser --disabled-password --uid 1001 --gid 1001 --gecos '' runner
      echo 'runner ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/98-runner
    COMMAND

    vm.sshable.cmd(command.gsub(/^(# .*)?\n/, ""))

    hop_setup_environment
  end

  def concurrency_available?
    github_runner.installation.project_dataset.for_update.all
    github_runner.installation.project.runner_core_limit > github_runner.installation.project.github_installations.sum(&:total_active_runner_cores)
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
      # the runner creates some configuration files at the script location. Since the
      # github runner vm is created with the runneradmin user, directory is first moved
      # to runneradmin user's home directory. At the end of this script, it will be moved
      # to runner user's home folder. We move actions-runner separately below for idempotency
      # purposes, as the first one guarantees to continue in case the script fails after that
      # line, and the latter guarateens to continue if the script fails after moving
      # actions-runner from ./ to /home/runner
      sudo [ ! -d /usr/local/share/actions-runner ] || sudo mv /usr/local/share/actions-runner ./
      sudo [ ! -d /home/runner/actions-runner ] || sudo mv /home/runner/actions-runner ./
      sudo chown -R runneradmin:runneradmin actions-runner

      # ./env.sh sets some variables for runner to run properly
      ./actions-runner/env.sh

      # Include /etc/environment in the runneradmin environment to move it to the
      # runner enviornment at the end of this script, it's otherwise ignored, and
      # this omission has caused problems.
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
      cat /imagegeneration/imagedata.json | jq '. += [#{setup_info.to_json}]' > ./actions-runner/.setup_info

      sudo mv ./actions-runner /home/runner/
      sudo chown -R runner:runner /home/runner/actions-runner
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
                   "/home/runner/actions-runner/run-withenv.sh {}",
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
      nap 15
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

      # If the runner is not assigned any job and we destroy it after a
      # timeline, the workflow_job is nil, in that case, we want to be able to
      # see journalctl output to debug if there was any problem with the runner
      # script.
      #
      # We also want to see the journalctl output if the runner script failed.
      #
      # Hence, the condition is added to check if the workflow_job is nil or
      # the conclusion is failure.
      if (job = github_runner.workflow_job).nil? || job.fetch("conclusion") != "success"
        begin
          serial_log_path = "/vm/#{vm.inhost_name}/serial.log"
          vm.vm_host.sshable.cmd("sudo ln #{serial_log_path} /var/log/ubicloud/serials/#{github_runner.ubid}_serial.log")

          # Exclude the "Started" line because it contains sensitive information.
          vm.sshable.cmd("journalctl -u runner-script --no-pager | grep -v -e Started -e sudo")
        rescue Sshable::SshError
          Clog.emit("Failed to move serial.log or running journalctl") { {github_runner: github_runner.values} }
        end
      end
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
