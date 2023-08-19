# frozen_string_literal: true

require "net/ssh"

class Prog::Test::HetznerServer < Prog::Base
  def self.assemble(hostname, server_identifier)
    Strand.create_with_id(
      prog: "Test::HetznerServer",
      label: "start",
      stack: [{hostname: hostname, server_identifier: server_identifier}]
    )
  end

  label def start
    hop_add_ssh_key
  end

  label def add_ssh_key
    keypair = SshKey.generate

    hetzner_api.add_key("ubicloud_ci_key_#{strand.ubid}", keypair.public_key)

    current_frame = strand.stack.first
    current_frame["hetzner_ssh_keypair"] = Base64.encode64(keypair.keypair)
    strand.modified!(:stack)
    strand.save_changes

    hop_reset
  end

  label def reset
    hetzner_api.reset(
      frame["server_identifier"],
      hetzner_ssh_key: hetzner_ssh_keypair.public_key
    )

    hop_wait_reset
  end

  label def wait_reset
    begin
      rootish_ssh("echo 1", hetzner_ssh_keypair.private_key)
    rescue
      nap 15
    end

    hop_setup_host
  end

  label def setup_host
    st = Prog::Vm::HostNexus.assemble(
      frame["hostname"],
      provider: "hetzner",
      hetzner_server_identifier: frame["server_identifier"]
    )

    current_frame = strand.stack.first
    current_frame["vm_host_id"] = st.id
    strand.modified!(:stack)
    strand.save_changes

    # invalidate frame so it's reloaded for subesequent statements in this method
    @frame = nil

    # BootstrapRhizome::start will override raw_private_key_1, so save the key in
    # raw_private_key_2. This will allow BootstrapRhizome::setup to do a root
    # ssh into the server.
    sshable.update(raw_private_key_2: hetzner_ssh_keypair.keypair)

    strand.add_child(st)

    hop_wait_setup_host
  end

  label def wait_setup_host
    reap

    hop_test_host if children_idle

    donate
  end

  label def test_host
    strand.add_child(Strand.create_with_id(
      prog: "Test::VmHost", label: "start", stack: [{subject_id: frame["vm_host_id"]}]
    ))

    hop_wait_test_host
  end

  label def wait_test_host
    reap

    hop_delete_key if children_idle

    donate
  end

  def children_idle
    active_children = strand.children_dataset.where(Sequel.~(label: "wait"))
    active_semaphores = strand.children_dataset.join(:semaphore, strand_id: :id)

    active_children.count == 0 and active_semaphores.count == 0
  end

  label def delete_key
    hetzner_api.delete_key(hetzner_ssh_keypair.public_key)

    hop_finish
  end

  label def finish
    Strand[vm_host.id].destroy
    vm_host.destroy
    sshable.destroy

    pop "HetznerServer tests finished!"
  end

  def hetzner_api
    # YYY: Remove the workaround for the "123" id.
    #
    # HetznerApis requires a HetznerHost, and HetznerHost.id saved to DB in a foreign
    # key VmHost.id, which we cannot create at this point. So as a workaround I create
    # a HetzenrHost which is not saved to DB, which requires an id.
    #
    # A proper change is to refactor HetznerApi to have less requirements.
    @hetzner_api ||= Hosting::HetznerApis.new(
      HetznerHost.new(server_identifier: frame["server_identifier"]) { _1.id = "123" }
    )
  end

  def rootish_ssh(cmd, private_key)
    Net::SSH.start(frame["hostname"], "root",
      key_data: [private_key],
      verify_host_key: :never,
      number_of_password_prompts: 0) do |ssh|
      ret = ssh.exec!(cmd)
      fail "Command exited with nonzero status" unless ret.exitstatus.zero?
      ret
    end
  end

  def hetzner_ssh_keypair
    @hetzner_ssh_keypair ||= SshKey.from_binary(Base64.decode64(frame["hetzner_ssh_keypair"]))
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def sshable
    @sshable ||= Sshable[frame["vm_host_id"]]
  end
end
