# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "vhost_block_backend"
require_relative "kek_pipe"
require "fileutils"
require "perfect_toml"

class DetachableVolume
  include KekPipe

  ROOT = "/var/storage/detachable"

  IMAGE_ROOT = "/var/storage/images"

  STRIPE_SHIFT = 11

  START_TIMEOUT = 30

  attr_reader :id, :dir

  def initialize(id, ubiblk_version: nil)
    raise ArgumentError, "invalid volume id: #{id.inspect}" unless /\Adv[0-9a-z]{24}\z/.match?(id)
    @id = id
    @dir = File.join(ROOT, id)
    @ubiblk_version = ubiblk_version
  end

  def disk_file = File.join(@dir, "disk.raw")

  def metadata_file = File.join(@dir, "metadata")

  def vhost_sock = File.join(@dir, "vhost.sock")

  def rpc_sock = File.join(@dir, "rpc.sock")

  def kek_pipe_path = File.join(@dir, "kek.pipe")

  def main_conf = File.join(@dir, "vhost-backend.conf")

  def staged_main_conf = "#{main_conf}.new"

  def source_conf = File.join(@dir, "vhost-backend-stripe-source.conf")

  def secrets_conf = File.join(@dir, "vhost-backend-secrets.conf")

  def unit = "dv-#{@id}-storage.service"

  def exist? = File.exist?(main_conf)

  def ensure_started(kek:, unix_user:, device_id:, slice:, size_gib:, wrapped_xts:, source:)
    unless exist?
      create(size_gib: size_gib, kek: kek, wrapped_xts: wrapped_xts, source: source,
        unix_user: unix_user, device_id: device_id)
    end
    start(kek, unix_user, slice: slice)
  end

  def create(size_gib:, kek:, wrapped_xts:, source:, unix_user:, device_id:)
    FileUtils.rm_rf(@dir)
    FileUtils.mkdir_p(@dir)
    FileUtils.chown(unix_user, unix_user, @dir)

    File.open(disk_file, File::CREAT | File::WRONLY) { |f| f.truncate(size_gib * 1024 * 1024 * 1024) }
    FileUtils.chown(unix_user, unix_user, disk_file)
    File.chmod(0o600, disk_file)

    write_configs(source: source, wrapped_xts: wrapped_xts, device_id: device_id, unix_user: unix_user)

    File.open(metadata_file, File::CREAT | File::WRONLY) { |f| f.truncate(8 * 1024 * 1024) }
    FileUtils.chown(unix_user, unix_user, metadata_file)
    init_metadata(kek, unix_user)
    File.rename(staged_main_conf, main_conf)
    sync_parent_dir(main_conf)
  rescue
    FileUtils.rm_rf(@dir)
    raise
  end

  def start(kek, unix_user, slice: nil)
    stop
    FileUtils.rm_f(vhost_sock)
    FileUtils.rm_f(rpc_sock)
    take_ownership(unix_user)
    write_unit(unix_user, slice)
    r("systemctl", "daemon-reload")

    with_kek_pipe(kek_pipe_path, owner: unix_user) do |pipe|
      r("systemctl", "start", unit)
      write_kek_to_pipe(pipe, kek)
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT
    until File.socket?(vhost_sock)
      fail "ubiblk never opened #{vhost_sock}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.001
    end
  end

  def write_configs(source:, wrapped_xts:, device_id:, unix_user:)
    includes = []
    includes << File.basename(source_conf) if source
    includes << File.basename(secrets_conf)

    write_file(staged_main_conf, unix_user, PerfectTOML.generate({
      "include" => includes,
      "device" => {
        "data_path" => disk_file,
        "vhost_socket" => vhost_sock,
        "rpc_socket" => rpc_sock,
        "device_id" => device_id,
        "track_written" => true,
        "metadata_path" => metadata_file,
      },
      "tuning" => {
        "num_queues" => 1,
        "queue_size" => 64,
        "seg_size_max" => 65536,
        "seg_count_max" => 4,
        "poll_timeout_us" => 1000,
        "write_through" => false,
      },
      "encryption" => {"xts_key" => {"ref" => "xts-key"}},
    }))

    secrets = {
      "xts-key" => wrapped_secret(wrapped_xts),
      "kek" => {"encoding" => "base64", "source" => {"file" => kek_pipe_path}},
    }
    write_file(secrets_conf, unix_user, PerfectTOML.generate({"secrets" => secrets}))
    write_file(source_conf, unix_user, stripe_source_toml(source)) if source
  end

  def init_metadata(kek, unix_user)
    cmd = ["sudo", "-u", unix_user, backend.init_metadata_path,
      "-s", STRIPE_SHIFT.to_s, "--config", staged_main_conf]
    run_with_kek_pipe(cmd, kek_pipe: kek_pipe_path, kek_content: kek, owner: unix_user)
  end

  def take_ownership(unix_user)
    FileUtils.chown_R(unix_user, unix_user, @dir)
  end

  def write_unit(unix_user, slice = nil)
    safe_write_to_file("/etc/systemd/system/#{unit}", <<~UNIT)
      [Unit]
      Description=Detachable volume #{@id}
      After=network.target

      [Service]
      #{"Slice=#{slice}" if slice}
      Environment=RUST_LOG=info
      ExecStart=#{backend.bin_path} --config #{main_conf}
      Restart=no
      User=#{unix_user}
      Group=#{unix_user}
      NoNewPrivileges=true
      ProtectSystem=full
      ReadWritePaths=#{@dir}
      PrivateTmp=true
      ProtectKernelModules=true
      ProtectKernelTunables=true
      ProtectControlGroups=true
      RestrictNamespaces=true
      RestrictSUIDSGID=yes
      MemoryDenyWriteExecute=yes

      [Install]
      WantedBy=multi-user.target
    UNIT
  end

  def write_file(path, unix_user, content)
    safe_write_to_file(path, content, perm: 0o600)
    FileUtils.chown(unix_user, unix_user, path)
  end

  def stripe_source_toml(source)
    stripe_source = case source["type"]
    when "new", "raw"
      {"type" => "raw", "image_path" => File.join(IMAGE_ROOT, "#{source["image"]}.raw"), "copy_on_read" => true}
    else
      fail "unsupported stripe source #{source["type"]}"
    end
    PerfectTOML.generate({"stripe_source" => stripe_source})
  end

  def backend
    fail "running the backend needs a ubiblk version" unless @ubiblk_version
    @backend ||= VhostBlockBackend.new(@ubiblk_version)
  end

  def wrapped_secret(inline)
    {"encoding" => "base64", "source" => {"inline" => inline}, "encrypted_by" => {"ref" => "kek"}}
  end

  def stop
    r("systemctl", "stop", unit)
  rescue CommandFail
    nil
  end

  def destroy
    stop
    FileUtils.rm_f("/etc/systemd/system/#{unit}")
    FileUtils.rm_rf(@dir)
  end
end
