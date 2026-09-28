# frozen_string_literal: true

require_relative "storage_volume"
require "socket"

# A ubiblk volume that isn't tied to a VM. It is laid out and run like a VM
# disk, but lives in a directory of its own, has a backend service named after
# it, and is owned by the user of whichever VM it is attached to, which can
# change between starts.
class DetachableVolume < StorageVolume
  attr_reader :id

  # owner is the unix user of the VM the volume is attached to, and params
  # are the volume's StorageVolume parameters. Neither is needed to delete
  # the volume.
  def initialize(id, owner = nil, params = {})
    @id = id
    super(owner, {"encrypted" => true}.merge(params))
  end

  def sp
    @sp ||= StoragePath.detachable(@id)
  end

  # Lays the volume out afresh if asked to, over whatever an interrupted
  # layout left, and starts it.
  def ensure_started(key_wrapping_secrets, lay_out:)
    fail "detachable volumes need a vhost block backend with config v2" unless use_config_v2?
    return start(key_wrapping_secrets) unless lay_out

    # A retried start may find the backend of an earlier attempt still
    # running, so stop it before removing the files from under it.
    stop_service_if_loaded(vhost_user_block_service)
    rm_if_exists(storage_dir)
    begin
      prep(key_wrapping_secrets)
      start(key_wrapping_secrets)
    rescue
      # The control plane records the volume's host only once a start
      # succeeds, so destroying the volume wouldn't remove what this left.
      delete
      raise
    end
  end

  # The volume may be started for a different VM than it was last used by, so
  # hand it and its service to that VM's user first.
  def vhost_backend_start(key_wrapping_secrets)
    stop_service_if_loaded(vhost_user_block_service)
    FileUtils.chown_R(@vm_name, @vm_name, storage_dir)
    vhost_backend_create_service_file
    r "systemctl", "daemon-reload"
    super
  end

  # A volume restarted on the same host is started without its remote source
  # in its parameters, but its config on disk may still read from one.
  def needs_network?
    super || remote_source?
  end

  def service_description
    "Vhost Block Backend Service for detachable volume #{@id}"
  end

  def exist? = File.exist?(sp.vhost_backend_config)

  def stop
    stop_service_if_loaded(sp.vhost_backend_service)
  end

  def delete
    purge_vhost_backend
    rm_if_exists(storage_dir)
  end

  def status
    return {"present" => false, "stripes" => {}, "caught_up" => true} unless exist?
    counts = stripes
    {"present" => true, "stripes" => counts, "caught_up" => caught_up?(counts)}
  end

  def stripes
    rpc("status").dig("status", "stripes") || {}
  end

  # Caught up once every stripe has been fetched from the remote source, and
  # not while the backend can't say, as when it is stopped.
  def caught_up?(counts = nil)
    return true unless remote_source?
    counts ||= stripes
    return false unless counts.key?("fetched") && counts.key?("source")
    counts["fetched"] >= counts["source"]
  end

  def rpc(command)
    line = UNIXSocket.open(sp.rpc_socket_path) do |socket|
      socket.write(JSON.generate({"command" => command}) + "\n")
      socket.gets
    end
    JSON.parse(line.to_s)
  rescue SystemCallError, JSON::ParserError
    {}
  end

  def remote_source?
    File.exist?(sp.vhost_backend_stripe_source_config) &&
      PerfectTOML.load_file(sp.vhost_backend_stripe_source_config).dig("stripe_source", "type") == "remote"
  end

  def start_autofetch
    rpc("start_autofetch")
  end
end
