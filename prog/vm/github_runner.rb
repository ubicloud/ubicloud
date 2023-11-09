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
    project = github_runner.installation.project
    label_data = Github.runner_labels[label]
    pool = VmPool.where(
      vm_size: label_data["vm_size"],
      boot_image: label_data["boot_image"],
      location: label_data["location"],
      storage_size_gib: label_data["storage_size_gib"]
    ).first

    if (picked_vm = pool&.pick_vm)
      picked_vm.associate_with_project(project)
      picked_vm.private_subnets.each { |ps| ps.associate_with_project(project) }

      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: picked_vm.id,
        resource_name: picked_vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmCores", picked_vm.family, picked_vm.location)["id"],
        amount: picked_vm.cores
      )

      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: picked_vm.assigned_vm_address.id,
        resource_name: picked_vm.assigned_vm_address.ip,
        billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", picked_vm.location)["id"],
        amount: 1
      )
      Clog.emit("Pool is used") { {github_runner: {label: github_runner.label, repository_name: github_runner.repository_name, cores: picked_vm.cores}} }
      return picked_vm
    end

    # We use unencrypted storage for now, because provisioning 86G encrypted
    # storage takes ~8 minutes. Unencrypted disk uses `cp` command instead
    # of `spdk_dd` and takes ~3 minutes. If btrfs disk mounted, it decreases to
    # ~10 seconds.
    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "runner",
      project.id,
      name: github_runner.ubid.to_s,
      size: label_data["vm_size"],
      location: label_data["location"],
      boot_image: label_data["boot_image"],
      storage_volumes: [{size_gib: label_data["storage_size_gib"], encrypted: false}],
      enable_ip4: true
    )

    ps = vm_st.subject.private_subnets.first
    ps.firewall_rules.map(&:destroy)
    ps.incr_update_firewall_rules
    Clog.emit("Pool is empty") { {github_runner: {label: github_runner.label, repository_name: github_runner.repository_name, cores: vm_st.subject.cores}} }
    vm_st.subject
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
    hop_install_nftables_rules
  end

  label def install_nftables_rules
    # Prevent other ports listening to traffic unless they send
    # traffic first, i.e. "outbound only" connections, save SSH that
    # clover uses to manipulate things.
    install_ssh_listen_only_nftables_chain
    hop_setup_environment
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

      # runner script doesn't use global $PATH variable by default. It gets path from
      # secure_path at /etc/sudoers. Also script load .env file, so we are able to
      # overwrite default path value of runner script with $PATH.
      # https://github.com/microsoft/azure-pipelines-agent/issues/3461
      echo "PATH=$PATH" >> ./actions-runner/.env
    COMMAND

    # Remove comments and empty lines before sending them to the machine
    vm.sshable.cmd(command.gsub(/^(#.*)?\n/, ""))

    hop_register_runner
  end

  label def register_runner
    # We use generate-jitconfig instead of registration-token because it's
    # recommended by GitHub for security reasons.
    # https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-just-in-time-runners
    data = {name: github_runner.ubid.to_s, labels: [github_runner.label], runner_group_id: 1}
    response = github_client.post("/repos/#{github_runner.repository_name}/actions/runners/generate-jitconfig", data)
    github_runner.update(runner_id: response[:runner][:id], ready_at: Time.now)

    # We initiate an API call and a SSH connection under the same label to avoid
    # having to store the encoded_jit_config.
    vm.sshable.cmd("sudo -- xargs -I{} -- systemd-run --uid runner --gid runner " \
                   "--working-directory '/home/runner' --unit #{SERVICE_NAME} --remain-after-exit -- " \
                   "./actions-runner/run.sh --jitconfig {}",
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

    # If the runner doesn't pick a job in two minutes, destroy it
    if github_runner.job_id.nil? && Time.now > github_runner.ready_at + 60 * 2
      response = github_client.get("/repos/#{github_runner.repository_name}/actions/runners/#{github_runner.runner_id}")
      unless response[:busy]
        github_runner.incr_destroy
        Clog.emit("Destroying GithubRunner because it does not pick a job in two minutes") { {github_runner: github_runner.values} }
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

  def tun_mac_addresses
    load_ip_netns_link.filter_map { _1.dig("linkinfo", "info_kind") == "tun" && _1.fetch("address") }
  end

  def load_ip_netns_link
    JSON.parse(vm.vm_host.sshable.cmd("sudo -- ip --detail --json --netns #{vm.inhost_name.shellescape} link"))
  end

  def install_ssh_listen_only_nftables_chain
    vm.sshable.cmd("sudo nft --file -", stdin: template_ssh_only_listen_nftable_conf)
  end

  def template_ssh_only_listen_nftable_conf
    internet_routing_mac_nft_set = '{"' + tun_mac_addresses.join('", "') + '"}'

    <<NFTABLES_CONF
# An nftables idiom for idempotent re-create of a named entity: merge
# in an empty table (a no-op if the table already exists) and then
# delete, before creating with a new definition.
table inet clover_github_actions;
delete table inet clover_github_actions;

table inet clover_github_actions {
  chain input {
    type filter hook input priority 0;

    # If a conntrack has been instantiated for a flow, allow the
    # packet through.

    # The trick in the rest of all this is to allow only the
    # current host to initiate the creation of entries in the
    # conntrack table, and they cannot be initiated from other
    # hosts on the Internet, with a notable exception for SSH.
    ct state vmap { established : accept, related : accept, invalid : drop }

    # Needed for neighbor solicitation at least to establish new
    # connections on IPv6, including DNS queries to IPv6 servers,
    # but on consideration of the goal of blocking attacks on
    # vulnerable GitHub Action payloads, it's okay to enable the
    # full ICMP suite for IPv4 and IPv6.
    meta l4proto { icmp, icmpv6 } accept

    # An exception to the "no connections initiated from the
    # Internet" rule, allow port 22/SSH to receive packets from the
    # internet without a conntrack state already established.
    # This is how Clover connects and controls the runner, so it's
    # obligatory.
    tcp dport 22 accept

    # Allow all other traffic that doesn't come from the host
    # forwarding, e.g. between interfaces on the system, as in
    # some uses of containers.  Our control over that is limited,
    # we want to not be debugging our interactions with GitHub's
    # pretty involved definition if we can avoid it.  Thus,
    # correlating it with a feature of the host's routing is one
    # way to narrowly define the behavior we want.
    ether saddr != #{internet_routing_mac_nft_set} accept

    # Finally, if passing no other conditions, drop all traffic
    # that comes from the host router hop.
    ether saddr #{internet_routing_mac_nft_set} drop
  }
}
NFTABLES_CONF
  end
end
