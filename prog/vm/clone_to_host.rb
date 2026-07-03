# frozen_string_literal: true

require "securerandom"

class Prog::Vm::CloneToHost < Prog::Base
  frame_accessor :target_vm_id, :remote_stripe_port, :psk_kek_id
  frame_reader :source_vm_id, :target_vm_host_id, :name, :public_key, :sshable_unix_user,
    :private_subnet_id, :size, :enable_ip4, :project_id, :destroy_source_after

  REMOTE_STRIPE_PORT_RANGE = 41000..41999

  def self.assemble(source_vm_id:, target_vm_host_id:, project_id:, name:, public_key:,
    sshable_unix_user: "ubi", private_subnet_id: nil, size: nil, enable_ip4: true,
    destroy_source_after: false)
    source_vm = Vm.with_pk!(source_vm_id)
    fail "source VM must have exactly one storage volume" unless source_vm.vm_storage_volumes.length == 1

    source_volume = source_vm.vm_storage_volumes.first
    fail "source VM's storage volume must have track_written enabled" unless source_volume.track_written
    fail "source VM's storage volume has not caught up" unless source_volume.caught_up?

    target_host = VmHost.with_pk!(target_vm_host_id)
    fail "target host is not accepting allocations" unless target_host.allocation_state == "accepting"

    DB.transaction do
      Strand.create(
        prog: "Vm::CloneToHost",
        label: "start",
        stack: [{
          "source_vm_id" => source_vm_id,
          "target_vm_host_id" => target_vm_host_id,
          "project_id" => project_id,
          "name" => name,
          "public_key" => public_key,
          "sshable_unix_user" => sshable_unix_user,
          "private_subnet_id" => private_subnet_id,
          "size" => size,
          "enable_ip4" => enable_ip4,
          "destroy_source_after" => destroy_source_after,
        }],
      )
    end
  end

  label def start
    source_vm.lock!
    # 4 hours is generous but not unbounded: covers a very slow clone of a
    # large disk over a slow link. The prog releases prevent_destroy on the
    # source and tears the server down at `finish`, so hitting the deadline
    # leaves neither the source nor the server hanging.
    register_deadline("finish", 4 * 60 * 60)
    source_vm.incr_prevent_destroy

    psk_kek = StorageKeyEncryptionKey.create_random(auth_data: "clone_to_host_#{source_vm.ubid}")
    self.psk_kek_id = psk_kek.id
    self.remote_stripe_port = SecureRandom.random_number(REMOTE_STRIPE_PORT_RANGE)

    hop_setup_source_stripe_server
  end

  label def setup_source_stripe_server
    sv = source_vm.vm_storage_volumes.first
    sshable = source_vm.vm_host.sshable

    # Write a listen-config TOML to the source host that binds the server on
    # the picked port with the generated PSK inline. Then start the ubiblk
    # `remote-stripe-server` binary under a daemonizer2 unit so we can d_check
    # / d_stop / d_clean it from later labels.
    sshable.cmd("sudo tee :listen_conf > /dev/null && sudo chmod 600 :listen_conf",
      listen_conf: listen_config_path(sv), stdin: listen_config_toml, log: false)
    sshable.d_run(stripe_unit,
      "sudo", remote_stripe_server_binary(sv),
      "--config", vhost_backend_config_path(sv),
      "--listen-config", listen_config_path(sv))
    hop_wait_source_stripe_server
  end

  label def wait_source_stripe_server
    case source_vm.vm_host.sshable.d_check(stripe_unit)
    when "InProgress"
      hop_create_target_vm
    when "Succeeded"
      # remote-stripe-server is long-lived; "Succeeded" means it exited
      # while we were waiting for it to come up.
      hop_failed
    when "Failed"
      hop_failed
    else
      nap 5
    end
  end

  label def create_target_vm
    endpoint = "#{source_vm.vm_host.sshable.host}:#{remote_stripe_port}"

    st = Prog::Vm::Nexus.assemble_with_sshable(
      project_id,
      name:,
      sshable_unix_user:,
      private_subnet_id:,
      size: size || source_vm.display_size,
      enable_ip4:,
      location_id: source_vm.vm_host.location_id,
      arch: source_vm.arch,
      force_host_id: target_vm_host_id,
      storage_volumes: [{
        size_gib: source_vm.vm_storage_volumes.first.size_gib,
        remote_stripe_endpoint: endpoint,
        remote_stripe_kek_id: psk_kek_id,
      }],
    )
    self.target_vm_id = st.id
    hop_wait_target_vm
  end

  label def wait_target_vm
    target = Vm[target_vm_id]
    nap 15 unless target&.display_state == "running"
    hop_wait_fetch_complete
  end

  label def wait_fetch_complete
    target = Vm[target_vm_id]
    nap 30 unless target.vm_storage_volumes.all?(&:caught_up?)
    hop_teardown_source_stripe_server
  end

  label def teardown_source_stripe_server
    sshable = source_vm.vm_host.sshable
    sshable.d_stop(stripe_unit) if sshable.d_check(stripe_unit) == "InProgress"
    sshable.d_clean(stripe_unit)
    source_vm.decr_prevent_destroy
    source_vm.incr_destroy if destroy_source_after
    hop_finish
  end

  label def finish
    pop "target_vm_id" => target_vm_id
  end

  label def failed
    nap 15
  end

  def source_vm
    @source_vm ||= Vm[source_vm_id]
  end

  def psk_kek
    @psk_kek ||= StorageKeyEncryptionKey[psk_kek_id]
  end

  def stripe_unit
    "clone_stripe_#{source_vm.ubid}"
  end

  def remote_stripe_server_binary(sv)
    "/opt/vhost-block-backend/#{sv.vhost_block_backend.version}/remote-stripe-server"
  end

  def storage_dir(sv)
    device = sv.storage_device.name
    root = (device == "DEFAULT") ? "/var/storage" : "/var/storage/devices/#{device}"
    "#{root}/#{source_vm.inhost_name}/#{sv.disk_index}"
  end

  def vhost_backend_config_path(sv)
    "#{storage_dir(sv)}/vhost-backend.conf"
  end

  def listen_config_path(sv)
    "#{storage_dir(sv)}/remote-stripe-listen.conf"
  end

  def listen_config_toml
    <<~TOML
      [server]
      address = "0.0.0.0:#{remote_stripe_port}"

      [server.psk]
      identity = "clone-client"
      secret.ref = "remote-psk"

      [secrets.remote-psk]
      source.inline = "#{psk_kek.key}"
      encoding = "base64"

      [danger_zone]
      enabled = true
      allow_inline_plaintext_secrets = true
    TOML
  end
end
