# frozen_string_literal: true

require "securerandom"

# Runs an ubiblk remote-stripe-server daemon on the host of a source volume,
# serving that volume over the remote stripe protocol (TLS-PSK) so another host
# can boot a VM from it. The daemon always uses the v0.5.0 backend, which can
# serve volumes created by older backends too.
class Prog::Storage::RemoteStorageServer::Nexus < Prog::Base
  subject_is :remote_storage_server

  PORT_RANGE = (5500..5999)

  # The server always runs the v0.5.0 remote-stripe-server binary, which can
  # serve volumes created by older backends (v0.2.x via --legacy, v0.4.x+
  # directly). The source volume can be on any backend version.
  SERVER_VERSION = "v0.5.0"

  # Given the volume to serve, figure out its host, pick a free port on that
  # host, mint a PSK, and start the server.
  def self.assemble(vm_storage_volume_id)
    source_volume = VmStorageVolume[vm_storage_volume_id]
    fail "No existing VmStorageVolume" unless source_volume
    fail "Source volume must be encrypted" unless source_volume.key_encryption_key_1

    DB.transaction do
      port = free_port(source_volume.vm.vm_host_id)
      ubid = RemoteStorageServer.generate_ubid
      id = ubid.to_uuid
      RemoteStorageServer.create_with_id(
        id,
        source_vm_storage_volume_id: source_volume.id,
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
      .join(:vm_storage_volume, id: :source_vm_storage_volume_id)
      .join(:vm, id: Sequel[:vm_storage_volume][:vm_id])
      .where(Sequel[:vm][:vm_host_id] => vm_host_id)
      .select_map(Sequel[:remote_storage_server][:port])
    PORT_RANGE.find { |port| !used.include?(port) } || fail("No free port for remote storage server")
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
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
    case sshable.d_check(daemon_name)
    when "InProgress"
      hop_wait
    when "Succeeded", "Failed", "NotStarted"
      start_daemon
    end
    nap 5
  end

  label def wait
    hop_run_server unless sshable.d_check(daemon_name) == "InProgress"
    nap 30
  end

  label def destroy
    decr_destroy
    sshable.d_stop(daemon_name)
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
    sshable.d_run(
      daemon_name,
      "sudo", "host/bin/setup-remote-storage-server",
      source.vm.inhost_name, source.storage_device.name, source.disk_index.to_s,
      source.vhost_block_backend_version, SERVER_VERSION, remote_storage_server.port.to_s,
      remote_storage_server.psk_identity,
      stdin: secrets.to_json,
    )
  end
end
