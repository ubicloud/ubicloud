# frozen_string_literal: true

require "net/ssh"

class Prog::Vm::GithubRunner < Prog::Base
  subject_is :github_runner

  def self.assemble(installation, repository_name:, label:, default_branch: nil)
    unless Github.runner_labels[label]
      fail "Invalid GitHub runner label: #{label}"
    end

    DB.transaction do
      repository = Prog::Github::GithubRepositoryNexus.assemble(installation, repository_name, default_branch).subject
      github_runner = GithubRunner.create_with_id(
        installation_id: installation.id,
        repository_name: repository_name,
        repository_id: repository.id,
        label: label
      )

      Strand.create(prog: "Vm::GithubRunner", label: "start") { _1.id = github_runner.id }
    end
  end

  def pick_vm
    skip_sync = true
    pool = VmPool.where(
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location_id: Location[name: label_data["location"]].id,
      storage_size_gib: label_data["storage_size_gib"],
      storage_encrypted: true,
      storage_skip_sync: skip_sync,
      arch: label_data["arch"]
    ).first

    if (picked_vm = pool&.pick_vm)
      return picked_vm
    end

    ps = Prog::Vnet::SubnetNexus.assemble(
      Config.github_runner_service_project_id,
      location_id: Location[name: label_data["location"]].id,
      allow_only_ssh: true
    ).subject

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "runneradmin",
      Config.github_runner_service_project_id,
      name: github_runner.ubid.to_s,
      size: label_data["vm_size"],
      location_id: Location[name: label_data["location"]].id,
      boot_image: label_data["boot_image"],
      storage_volumes: [{size_gib: label_data["storage_size_gib"], encrypted: true, skip_sync: skip_sync}],
      enable_ip4: true,
      arch: label_data["arch"],
      swap_size_bytes: 4294963200, # ~4096MB, the same value with GitHub hosted runners
      private_subnet_id: ps.id
    )

    vm_st.subject
  end

  def update_billing_record
    # If the runner is destroyed before it's ready or doesn't pick a job, don't charge for it.
    return unless github_runner.ready_at && github_runner.workflow_job

    project = github_runner.installation.project
    rate_id = if label_data["arch"] == "arm64"
      BillingRate.from_resource_properties("GitHubRunnerMinutes", "#{label_data["vm_size"]}-arm", "global")["id"]
    else
      BillingRate.from_resource_properties("GitHubRunnerMinutes", label_data["vm_size"], "global")["id"]
    end

    retries = 0
    begin
      begin_time = Time.now.to_date.to_time
      end_time = begin_time + 24 * 60 * 60
      duration = Time.now - github_runner.ready_at
      used_amount = (duration / 60).ceil
      github_runner.log_duration("runner_completed", duration)
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

  def vm
    @vm ||= github_runner.vm
  end

  def github_client
    @github_client ||= Github.installation_client(github_runner.installation.installation_id)
  end

  def label_data
    @label_data ||= Github.runner_labels[github_runner.label]
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_vm_destroy"].include?(strand.label)
        register_deadline(nil, 15 * 60)
        update_billing_record
        hop_destroy
      end
    end
  end

  label def start
    pop "Could not provision a runner for inactive project" unless github_runner.installation.project.active?
    hop_wait_concurrency_limit unless quota_available?
    hop_allocate_vm
  end

  label def wait_concurrency_limit
    hop_allocate_vm if quota_available?

    # check utilization, if it's high, wait for it to go down
    utilization = VmHost.where(allocation_state: "accepting", arch: label_data["arch"]).select_map {
      sum(:used_cores) * 100.0 / sum(:total_cores)
    }.first.to_f

    unless utilization < 70
      Clog.emit("Waiting for customer concurrency limit, utilization is high") { [github_runner, {utilization: utilization}] }
      nap rand(5..15)
    end

    Clog.emit("Concurrency limit reached but allocation is allowed because of low utilization") { [github_runner, {utilization: utilization}] }

    hop_allocate_vm
  end

  label def allocate_vm
    picked_vm = pick_vm
    github_runner.update(vm_id: picked_vm.id)
    picked_vm.update(name: github_runner.ubid.to_s)
    github_runner.reload.log_duration("runner_allocated", Time.now - github_runner.created_at)

    hop_wait_vm
  end

  label def wait_vm
    # If the vm is not allocated yet, we know that the vm provisioning will take
    # definitely more than 13 seconds.
    nap 13 unless vm.allocated_at
    nap 1 unless vm.provisioned_at
    register_deadline("wait", 10 * 60)
    hop_setup_environment
  end

  def quota_available?
    github_runner.installation.project_dataset.for_update.all
    # In existing Github quota calculations, we compare total allocated cpu count
    # with the cpu limit and allow passing the limit once. This is because we
    # check quota and allocate VMs in different labels hence transactions and it
    # is difficult to enforce quotas in the environment with lots of concurrent
    # requests. There are some remedies, but it would require some refactoring
    # that I'm not keen to do at the moment. Although it looks weird, passing 0
    # as requested_additional_usage keeps the existing behavior.
    github_runner.installation.project.quota_available?("GithubRunnerVCpu", 0)
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
        "Location" => Location[vm.vm_host.location_id].name,
        "Datacenter" => vm.vm_host.data_center,
        "Project" => github_runner.installation.project.ubid,
        "Console URL" => "#{Config.base_url}#{github_runner.installation.project.path}/github"
      }.map { "#{_1}: #{_2}" }.join("\n")
    }
  end

  label def setup_environment
    command = <<~COMMAND
      # To make sure the script errors out if any command fails
      set -ueo pipefail
      echo "image version: $ImageVersion"
      # runneradmin user on default Github hosted runners is a member of adm and
      # sudo groups. Having sudo access also allows us getting journalctl logs in
      # case of any issue on the destroy state below by runneradmin user.
      sudo usermod -a -G sudo,adm runneradmin

      # The `imagedata.json` file contains information about the generated image.
      # I enrich it with details about the Ubicloud environment and placed it in the runner's home directory.
      # GitHub-hosted runners also use this file as setup_info to show on the GitHub UI.
      jq '. += [#{setup_info.to_json}]' /imagegeneration/imagedata.json | sudo -u runner tee /home/runner/actions-runner/.setup_info

      # We use a JWT token to authenticate the virtual machines with our runtime API. This token is valid as long as the vm is running.
      # ubicloud/cache package which forked from the official actions/cache package, sends requests to UBICLOUD_CACHE_URL using this token.
      echo "UBICLOUD_RUNTIME_TOKEN=#{vm.runtime_token}
      UBICLOUD_CACHE_URL=#{Config.base_url}/runtime/github/" | sudo tee -a /etc/environment
    COMMAND

    if (mirror_vm = Vm[Config.docker_mirror_server_vm_id]) && vm.vm_host_id == mirror_vm.vm_host_id
      mirror_address = "#{mirror_vm.load_balancer.hostname}:5000"
      command += <<~COMMAND
        # Configure Docker daemon with registry mirror
        if [ -f /etc/docker/daemon.json ] && [ -s /etc/docker/daemon.json ]; then
          sudo jq '. + {"registry-mirrors": ["https://#{mirror_address}"]}' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.tmp
          sudo mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
        else
          echo '{"registry-mirrors": ["https://#{mirror_address}"]}' | sudo tee /etc/docker/daemon.json
        fi

        # Configure BuildKit to use the mirror
        sudo mkdir -p /etc/buildkit
        echo '
          [registry."docker.io"]
            mirrors = ["#{mirror_address}"]

          [registry."#{mirror_address}"]
            http = false
            insecure = false' | sudo tee -a /etc/buildkit/buildkitd.toml

        sudo systemctl daemon-reload
        sudo systemctl restart docker
      COMMAND
    end

    if github_runner.installation.cache_enabled
      command += <<~COMMAND
        echo "CUSTOM_ACTIONS_CACHE_URL=http://#{vm.private_ipv4}:51123/random_token/" | sudo tee -a /etc/environment
      COMMAND
    end

    # Remove comments and empty lines before sending them to the machine
    vm.sshable.cmd(command.gsub(/^(\s*# .*)?\n/, ""))

    hop_register_runner
  end

  label def register_runner
    # We use generate-jitconfig instead of registration-token because it's
    # recommended by GitHub for security reasons.
    # https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-just-in-time-runners
    data = {name: github_runner.ubid.to_s, labels: [github_runner.label], runner_group_id: 1, work_folder: "/home/runner/work"}
    response = github_client.post("/repos/#{github_runner.repository_name}/actions/runners/generate-jitconfig", data)
    github_runner.update(runner_id: response[:runner][:id], ready_at: Time.now)
    github_runner.log_duration("runner_registered", Time.now - github_runner.created_at)

    # We initiate an API call and a SSH connection under the same label to avoid
    # having to store the encoded_jit_config.
    vm.sshable.cmd("sudo -- xargs -I{} -- systemd-run --uid runner --gid runner " \
                   "--working-directory '/home/runner' --unit runner-script --remain-after-exit -- " \
                   "/home/runner/actions-runner/run-withenv.sh {}",
      stdin: response[:encoded_jit_config])

    hop_wait
  rescue Octokit::Conflict => e
    raise unless e.message.include?("Already exists")

    # If the runner already exists at GitHub side, this suggests that the
    # process terminated prematurely before hop wait. We can't be sure if the
    # script was started or not without checking the runner status. We need to
    # locate the runner using the name and decide delete or continue to wait.
    runners = github_client.paginate("/repos/#{github_runner.repository_name}/actions/runners") do |data, last_response|
      data[:runners].concat last_response.data[:runners]
    end
    unless (runner = runners[:runners].find { _1[:name] == github_runner.ubid.to_s })
      fail "BUG: Failed with runner already exists error but couldn't find it"
    end

    runner_id = runner.fetch(:id)
    # If the runner script is not started yet, we can delete the runner and
    # register it again.
    if vm.sshable.cmd("systemctl show -p SubState --value runner-script").chomp == "dead"
      Clog.emit("Deregistering runner because it already exists") { [github_runner, {existing_runner: {runner_id: runner_id}}] }
      github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{runner_id}")
      nap 5
    end

    # The runner script is already started. We persist the runner_id and allow
    # wait label to decide the next step.
    Clog.emit("The runner already exists but the runner script is started too") { [github_runner, {existing_runner: {runner_id: runner_id}}] }
    github_runner.update(runner_id: runner_id, ready_at: Time.now)
    hop_wait
  end

  label def wait
    case vm.sshable.cmd("systemctl show -p SubState --value runner-script").chomp
    when "exited"
      github_runner.incr_destroy
      nap 15
    when "failed"
      Clog.emit("The runner script failed") { github_runner }
      github_runner.provision_spare_runner
      github_runner.incr_destroy
      nap 0
    end

    # If the runner doesn't pick a job within five minutes, the job may have
    # been cancelled prior to assignment, so we destroy the runner. But we also
    # check if the runner is busy or not with GitHub API.
    if github_runner.workflow_job.nil? && Time.now > github_runner.ready_at + 5 * 60
      response = github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      unless response[:busy]
        Clog.emit("The runner does not pick a job") { github_runner }
        github_runner.incr_destroy
        nap 0
      end
    end

    nap 60
  end

  label def destroy
    decr_destroy

    # When we attempt to destroy the runner, we also deregister it from GitHub.
    # We wait to receive a 'not found' response for the runner. If the runner is
    # still running a job and, due to stale data, it gets mistakenly hopped to
    # destroy, this prevents the underlying VM from being destroyed and the job
    # from failing. However, in certain situations like fraudulent activity, we
    # might need to bypass this verification and immediately remove the runner.
    unless github_runner.skip_deregistration_set?
      begin
        response = github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
        if response[:busy]
          Clog.emit("The runner is still running a job") { github_runner }
          nap 15
        end
        github_client.delete("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
        nap 5
      rescue Octokit::NotFound
      end
    end

    if vm
      vm.private_subnets.each do |subnet|
        subnet.firewalls.map(&:destroy)
        subnet.incr_destroy
      end

      # If the runner is not assigned any job and we destroy it after a
      # timeline, the workflow_job is nil, in that case, we want to be able to
      # see journalctl output to debug if there was any problem with the runner
      # script.
      #
      # We also want to see the journalctl output if the runner script failed.
      #
      # Hence, the condition is added to check if the workflow_job is nil or
      # the conclusion is failure.
      if vm.vm_host && ((job = github_runner.workflow_job).nil? || job.fetch("conclusion") != "success")
        begin
          serial_log_path = "/vm/#{vm.inhost_name}/serial.log"
          vm.vm_host.sshable.cmd("sudo ln #{serial_log_path} /var/log/ubicloud/serials/#{github_runner.ubid}_serial.log")

          # We grep only the lines related to 'run-withenv' and 'systemd'. Other
          # logs include outputs from subprocesses like php, sudo, etc., which
          # could contain sensitive data. 'run-withenv' is the main process,
          # while systemd lines provide valuable insights into the lifecycle of
          # the runner script, including OOM issues.
          # We exclude the 'Started' line to avoid exposing the JIT token.
          vm.sshable.cmd("journalctl -u runner-script -t 'run-withenv.sh' -t 'systemd' --no-pager | grep -Fv Started")
        rescue Sshable::SshError
          Clog.emit("Failed to move serial.log or running journalctl") { github_runner }
        end
      end
      vm.incr_destroy
    end

    hop_wait_vm_destroy
  end

  label def wait_vm_destroy
    register_deadline(nil, 15 * 60, allow_extension: true) if vm&.prevent_destroy_set?
    nap 10 unless vm.nil?

    github_runner.destroy
    pop "github runner deleted"
  end
end
