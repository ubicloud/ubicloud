# frozen_string_literal: true

require "securerandom"

# Runs an ubiblk remote-stripe-server daemon on the host of a source volume,
# serving that volume over the remote stripe protocol (TLS-PSK) so another host
# can boot a VM from it.
class Prog::Storage::RemoteStorageServer::Nexus < Prog::Base
  subject_is :remote_storage_server

  PORT_RANGE = (5500..5999)

  # The server always runs the remote-stripe-server binary, which can
  # serve volumes created by older backends.
  SERVER_VERSION_CODE = 501

  # Given the volume to serve, figure out its host, pick a free port on that
  # host, create a PSK, and start the server.
  def self.assemble(vm_storage_volume_id)
    source_volume = VmStorageVolume[vm_storage_volume_id]
    fail "No existing VmStorageVolume" unless source_volume
    fail "Source volume must be encrypted" unless source_volume.key_encryption_key_1
    vm = source_volume.vm
    vm_host = vm.vm_host
    fail "VM isn't in stopped_by_admin state" unless vm.strand.label == "stopped_by_admin"
    fail "Host doesn't have ubiblk v0.5.1+" if vm_host.vhost_block_backends_dataset.where { version_code >= SERVER_VERSION_CODE }.empty?

    DB.transaction do
      port = free_port(vm_host.id)
      ubid = RemoteStorageServer.generate_ubid
      id = ubid.to_uuid
      RemoteStorageServer.create_with_id(
        id,
        source_vm_storage_volume_id: source_volume.id,
        vm_host_id: vm_host.id,
        psk: Base64.strict_encode64(SecureRandom.bytes(32)),
        psk_identity: ubid.to_s,
        port:,
      )
      Strand.create_with_id(id, prog: "Storage::RemoteStorageServer::Nexus", label: "start")
    end
  end

  # The lowest port in PORT_RANGE not already used by a remote storage server on
  # the same host.
  def self.free_port(vm_host_id)
    used = RemoteStorageServer
      .where(vm_host_id:)
      .select_set(:port)
    PORT_RANGE.find { |port| !used.include?(port) } || fail("No free port for remote storage server")
  end

  label def start
    register_deadline("wait", 5 * 60)
    # The source volume's vhost backend keeps running when its VM is stopped, so
    # it still holds the disk and the kek pipe. Stop it so the remote server can
    # open the volume exclusively. The source VM cannot run again until its
    # storage is restarted, which is the intended migration semantics.
    source = remote_storage_server.source_vm_storage_volume
    sshable.cmd("sudo systemctl stop :unit", unit: source.vhost_backend_systemd_unit_name)
    hop_run_server
  end

  label def run_server
    case state = sshable.d_check(daemon_name)
    when "InProgress"
      hop_wait
    when "Failed", "NotStarted"
      start_daemon
    else
      Clog.emit("Remote storage server in unexpected state", {remote_storage_server_unexpected_state: {state:}})
      start_daemon
    end
    nap 5
  end

  label def wait
    unless sshable.d_check(daemon_name) == "InProgress"
      register_deadline("wait", 5 * 60)
      hop_run_server
    end
    nap 30
  end

  label def destroy
    decr_destroy
    if sshable.d_check(daemon_name) == "InProgress"
      sshable.d_stop(daemon_name)
    end
    sshable.d_clean(daemon_name)
    remote_storage_server.destroy
    pop "remote storage server destroyed"
  end

  def sshable
    remote_storage_server.vm_host.sshable
  end

  def daemon_name
    "remote_stripe_server_#{remote_storage_server.ubid}"
  end

  # Start the daemon, delivering the source volume's KEK and the PSK over stdin
  # (never written to the host in the clear) so the host-side helper can serve
  # the (encrypted) source volume with TLS-PSK.
  def start_daemon
    source = remote_storage_server.source_vm_storage_volume
    secrets = {
      "kek" => source.key_encryption_key_1.secret_key_material_hash,
      "psk" => remote_storage_server.psk,
    }
    target_vbb_version = remote_storage_server
      .vm_host
      .vhost_block_backends_dataset
      .reverse(:version_code)
      .first { version_code >= SERVER_VERSION_CODE }
      .version
    sshable.d_run(
      daemon_name,
      "sudo", "host/bin/setup-remote-storage-server",
      source.vm.inhost_name, source.storage_device.name, source.disk_index.to_s,
      source.vhost_block_backend_version, target_vbb_version, remote_storage_server.port.to_s,
      remote_storage_server.psk_identity,
      stdin: secrets.to_json,
    )
  end
end
