# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "json"
require "openssl"
require "base64"
require "timeout"
require "yaml"
require_relative "boot_image"
require_relative "vm_path"
require_relative "spdk_path"
require_relative "spdk_rpc"
require_relative "spdk_setup"
require_relative "storage_key_encryption"
require_relative "storage_path"
require_relative "vhost_block_backend"

KEK_PIPE_WRITE_TIMEOUT_SEC = 5

class StorageVolume
  attr_reader :image_path, :read_only
  def initialize(vm_name, params)
    @vm_name = vm_name
    @vhost_backend_version = params["vhost_block_backend_version"]
    @disk_index = params["disk_index"]
    @device_id = params["device_id"]
    @encrypted = params["encrypted"]
    @disk_size_gib = params["size_gib"]
    @use_bdev_ubi = params["use_bdev_ubi"] || false
    @image_path = BootImage.new(params["image"], params["image_version"]).image_path if params["image"]
    @device = params["storage_device"] || DEFAULT_STORAGE_DEVICE
    @spdk_version = params["spdk_version"]
    @read_only = params["read_only"] || false
    @max_read_mbytes_per_sec = params["max_read_mbytes_per_sec"]
    @max_write_mbytes_per_sec = params["max_write_mbytes_per_sec"]
    @slice = params.fetch("slice_name", "system.slice")
    @num_queues = params.fetch("num_queues", 1)
    @queue_size = params.fetch("queue_size", 256)
    @copy_on_read = params.fetch("copy_on_read", false)
    @stripe_sector_count_shift = Integer(params.fetch("stripe_sector_count_shift", 11))
    @cpus = params["cpus"]

    # Machine image archive params (for UMI-backed volumes)
    @archive_params = params["machine_image"]
  end

  def archive?
    !@archive_params.nil?
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def rpc_client
    @rpc_client ||= SpdkRpc.new(SpdkPath.rpc_sock(@spdk_version))
  end

  def vhost_backend
    @vhost_backend ||= VhostBlockBackend.new(@vhost_backend_version)
  end

  def use_config_v2?
    @vhost_backend_version && vhost_backend.config_v2?
  end

  def prep(key_wrapping_secrets)
    # Device path is intended to be created by system admin, so fail loudly if
    # it doesn't exist
    fail "Storage device directory doesn't exist: #{sp.device_path}" if !File.exist?(sp.device_path)

    FileUtils.mkdir_p storage_dir
    FileUtils.chown @vm_name, @vm_name, storage_dir
    encryption_key = setup_data_encryption_key(key_wrapping_secrets) if @encrypted

    if @vhost_backend_version
      create_empty_disk_file
      prep_vhost_backend(encryption_key, key_wrapping_secrets)
      return
    end

    if @image_path.nil?
      fail "bdev_ubi requires a base image" if @use_bdev_ubi

      create_empty_disk_file
      return
    end

    verify_imaged_disk_size

    if @use_bdev_ubi
      create_ubi_writespace(encryption_key)
    elsif @encrypted
      create_empty_disk_file
      encrypted_image_copy(encryption_key, @image_path)
    else
      unencrypted_image_copy
    end
  end

  def prep_vhost_backend(encryption_key, key_wrapping_secrets)
    vhost_backend_create_config(encryption_key, key_wrapping_secrets)
    vhost_backend_create_metadata(key_wrapping_secrets)
    vhost_backend_create_service_file
  end

  def write_new_file(path, user)
    rm_if_exists(path)

    safe_write_to_file(path) do |file|
      File.chmod(0o600, file.path)
      FileUtils.chown user, user, file.path
      yield file
    end

    sync_parent_dir(path)
  end

  def vhost_backend_create_config(encryption_key, key_wrapping_secrets)
    if use_config_v2?
      write_config_file(sp.vhost_backend_stripe_source_config, v2_stripe_source_toml) if @image_path || archive?
      write_config_file(sp.vhost_backend_secrets_config, v2_secrets_toml(encryption_key, key_wrapping_secrets)) if @encrypted || archive?
      write_config_file(sp.vhost_backend_config, v2_main_toml)
    else
      config = vhost_backend_config(encryption_key, key_wrapping_secrets)
      write_config_file(sp.vhost_backend_config, config.to_yaml)
    end
  end

  def write_config_file(path, content)
    write_new_file(path, @vm_name) do |file|
      file.write(content)
      fsync_or_fail(file)
    end
  end

  def vhost_backend_create_metadata(key_wrapping_secrets)
    metadata_path = sp.vhost_backend_metadata
    config_path = sp.vhost_backend_config

    write_new_file(metadata_path, @vm_name) do |file|
      file.truncate(8 * 1024 * 1024)
    end

    if @encrypted
      vhost_backend_create_encrypted_metadata(key_wrapping_secrets)
    else
      r("sudo", "-u", @vm_name, vhost_backend.init_metadata_path, "-s", @stripe_sector_count_shift.to_s, "--config", config_path)
    end

    sync_parent_dir(metadata_path)
  end

  def vhost_backend_create_encrypted_metadata(key_wrapping_secrets)
    with_kek_pipe do |kek_pipe|
      cmd = [
        "sudo", "-u", @vm_name,
        vhost_backend.init_metadata_path,
        "-s", @stripe_sector_count_shift.to_s,
        "--config", sp.vhost_backend_config
      ]

      unless use_config_v2?
        # Unlike v2, where the kek path is explicitly included in the TOML
        # config, we need to pass the kek pipe path as a CLI arg in v1.
        cmd.push("--kek", kek_pipe)
      end

      # Start backend (it should open the FIFO for reading)
      pid = Process.spawn(*cmd)

      begin
        write_kek_to_pipe(kek_pipe, vhost_backend_kek(key_wrapping_secrets))
      rescue => e
        Process.kill("TERM", pid)
        Process.waitpid(pid)
        raise "init_metadata failed: error writing KEK to pipe: #{e.message}"
      end

      _, status = Process.wait2(pid)
      raise "init_metadata failed" unless status.success?
    end
  end

  def vhost_backend_create_service_file
    # v2 config embeds the kek pipe path in the TOML, so no --kek CLI arg needed
    kek_arg = if @encrypted && !use_config_v2?
      "--kek #{sp.kek_pipe}"
    end

    # systemd-analyze security result:
    # Overall exposure level for #{vhost_user_block_service}: 0.5 SAFE
    service_file_path = "/etc/systemd/system/#{vhost_user_block_service}"
    File.write(service_file_path, <<~SERVICE)
        [Unit]
        Description=Vhost Block Backend Service for #{@vm_name}
        After=network.target

        [Service]
        Slice=#{@slice}
        Environment=RUST_LOG=info
        Environment=RUST_BACKTRACE=1
        ExecStart=#{vhost_backend.bin_path} --config #{sp.vhost_backend_config} #{kek_arg}
        Restart=always
        User=#{@vm_name}
        Group=#{@vm_name}
        #{systemd_io_rate_limits}

        RemoveIPC=true
        NoNewPrivileges=true
        CapabilityBoundingSet=
        AmbientCapabilities=
        
        PrivateDevices=true
        DevicePolicy=closed
        DeviceAllow=/dev/null rw
        DeviceAllow=/dev/zero rw
        DeviceAllow=/dev/urandom rw
        DeviceAllow=/dev/random rw

        ProtectSystem=full
        ProtectHome=tmpfs
        ReadWritePaths=#{storage_root}
        PrivateTmp=true
        PrivateMounts=true

        ProtectKernelModules=true
        ProtectKernelTunables=true
        ProtectControlGroups=true
        ProtectClock=true
        ProtectHostname=true
        LockPersonality=true
        ProtectKernelLogs=true
        ProtectProc=invisible
        
        RestrictAddressFamilies=#{archive? ? "AF_UNIX AF_INET AF_INET6" : "AF_UNIX"}
        RestrictNamespaces=true
        SystemCallArchitectures=native
        SystemCallFilter=@system-service

        MemoryDenyWriteExecute=yes
        RestrictSUIDSGID=yes
        RestrictRealtime=yes
        ProcSubset=pid
        #{"PrivateNetwork=yes" unless archive?}
        PrivateUsers=yes
        #{"IPAddressDeny=any" unless archive?}

        [Install]
        WantedBy=multi-user.target
    SERVICE
  end

  def systemd_io_rate_limits
    limits = {IOReadBandwidthMax: @max_read_mbytes_per_sec,
              IOWriteBandwidthMax: @max_write_mbytes_per_sec}.compact
    return "" if limits.empty?

    dev = persistent_device_id(storage_dir)
    limits
      .map { |(key, mb)| "#{key}=#{dev} #{mb * 1024 * 1024}" }
      .join("\n")
  end

  def persistent_device_id(path)
    path_stat = File.stat(path)

    Dir["/dev/disk/by-id/*"].each do |id|
      dev_path = File.realpath(id)
      dev_stat = File.stat(dev_path)
      next unless dev_stat.rdev_major == path_stat.dev_major && dev_stat.rdev_minor == path_stat.dev_minor

      # Choose stable symlink types by subsystem:
      #  - SSDs: Use identifiers starting with 'wwn' (World Wide Name), globally unique.
      #  - NVMe: Use identifiers starting with 'nvme-eui', also globally unique.
      #  - MD devices: Use uuid identifiers.
      dev = File.basename(dev_path)
      return id if (dev.start_with?("nvme") && id.include?("nvme-eui.")) ||
        (dev.start_with?("sd") && id.include?("wwn-")) ||
        (dev.start_with?("md") && id.include?("md-uuid-"))
    rescue SystemCallError
      next
    end

    raise "No persistent device ID found for storage path: #{path}"
  end

  def wrap_key_b64(storage_key_encryption, key)
    key_bytes = [key].pack("H*")
    wrapped_key = storage_key_encryption.wrap_key(key_bytes).join
    Base64.strict_encode64(wrapped_key).strip
  end

  def vhost_backend_config(encryption_key, key_wrapping_secrets)
    config = {
      "path" => disk_file,
      "socket" => vhost_sock,
      "num_queues" => @num_queues,
      "queue_size" => @queue_size,
      "seg_size_max" => 64 * 1024,
      "seg_count_max" => 4,
      "copy_on_read" => @copy_on_read,
      "poll_queue_timeout_us" => 1000,
      "device_id" => @device_id,
      "write_through" => write_through_device?,
      "rpc_socket_path" => sp.rpc_socket_path
    }

    if @image_path
      config["image_path"] = @image_path
      config["metadata_path"] = sp.vhost_backend_metadata
    end

    if @encrypted
      key_encryption = StorageKeyEncryption.new(key_wrapping_secrets)
      key1_wrapped_b64 = wrap_key_b64(key_encryption, encryption_key[:key])
      key2_wrapped_b64 = wrap_key_b64(key_encryption, encryption_key[:key2])
      config["encryption_key"] = [key1_wrapped_b64, key2_wrapped_b64]
    end

    if @cpus
      config["cpus"] = @cpus
      config["num_queues"] = @cpus.count
    end

    config
  end

  def v2_main_toml
    sections = []
    sections << v2_include_section
    sections << v2_device_section
    sections << v2_tuning_section
    sections << if @encrypted
      v2_encryption_section
    else
      # unencrypted disks must be explicitly allowed in config v2.
      v2_danger_zone_section
    end
    sections.join("\n")
  end

  def v2_include_section
    includes = []
    includes << File.basename(sp.vhost_backend_stripe_source_config) if @image_path || archive?
    includes << File.basename(sp.vhost_backend_secrets_config) if @encrypted || archive?
    return "" if includes.empty?
    items = includes.map { |f| toml_str(f) }.join(", ")
    "include = [#{items}]\n"
  end

  def v2_device_section
    hash = {
      "data_path" => disk_file,
      "vhost_socket" => vhost_sock,
      "rpc_socket" => sp.rpc_socket_path,
      "device_id" => @device_id,
      "metadata_path" => sp.vhost_backend_metadata,
      "track_written" => true
    }
    toml_section("device", hash)
  end

  def v2_tuning_section
    hash = {
      "num_queues" => @cpus ? @cpus.count : @num_queues,
      "queue_size" => @queue_size,
      "seg_size_max" => 64 * 1024,
      "seg_count_max" => 4,
      "poll_timeout_us" => 1000,
      "write_through" => write_through_device?,
      "cpus" => @cpus
    }
    toml_section("tuning", hash.compact)
  end

  def v2_encryption_section
    hash = {
      "xts_key.ref" => "xts-key"
    }
    toml_section("encryption", hash)
  end

  def v2_danger_zone_section
    hash = {
      "enabled" => true,
      "allow_unencrypted_disk" => true
    }
    toml_section("danger_zone", hash)
  end

  def v2_secrets_toml(encryption_key, key_wrapping_secrets)
    kek_bytes = Base64.decode64(key_wrapping_secrets["key"])
    sections = []

    if @encrypted && encryption_key
      xts_plaintext = [encryption_key[:key]].pack("H*") + [encryption_key[:key2]].pack("H*")
      xts_key_name = "xts-key" # we use the key name as auth_data in aes256-gcm
      wrapped_xts_b64 = Base64.strict_encode64(
        StorageKeyEncryption.aes256gcm_encrypt(kek_bytes, xts_key_name, xts_plaintext)
      )

      sections << toml_section("secrets.#{xts_key_name}", {
        "source.inline" => wrapped_xts_b64,
        "encoding" => "base64",
        "encrypted_by.ref" => "kek"
      })
    end

    if archive?
      sections << v2_archive_secrets_toml(kek_bytes, key_wrapping_secrets)
    end

    sections << toml_section("secrets.kek", {
      "source.file" => sp.kek_pipe,
      "encoding" => "base64"
    })

    sections.join("\n")
  end

  def v2_archive_secrets_toml(kek_bytes, key_wrapping_secrets)
    sections = []

    # S3 credentials encrypted by disk KEK, inlined in TOML
    s3_key_id = key_wrapping_secrets["archive_s3_access_key"]
    sections << toml_section("secrets.s3-key-id", {
      "source.inline" => Base64.strict_encode64(
        StorageKeyEncryption.aes256gcm_encrypt(kek_bytes, "s3-key-id", s3_key_id)
      ),
      "encoding" => "base64",
      "encrypted_by.ref" => "kek"
    })

    s3_secret_key = key_wrapping_secrets["archive_s3_secret_key"]
    sections << toml_section("secrets.s3-secret-key", {
      "source.inline" => Base64.strict_encode64(
        StorageKeyEncryption.aes256gcm_encrypt(kek_bytes, "s3-secret-key", s3_secret_key)
      ),
      "encoding" => "base64",
      "encrypted_by.ref" => "kek"
    })

    if key_wrapping_secrets["archive_s3_session_token"]
      s3_session_token = key_wrapping_secrets["archive_s3_session_token"]
      sections << toml_section("secrets.s3-session-token", {
        "source.inline" => Base64.strict_encode64(
          StorageKeyEncryption.aes256gcm_encrypt(kek_bytes, "s3-session-token", s3_session_token)
        ),
        "encoding" => "base64",
        "encrypted_by.ref" => "kek"
      })
    end

    # Archive KEK (for encrypted archives)
    if @archive_params["encrypted"]
      archive_kek = Base64.decode64(key_wrapping_secrets["archive_kek"])
      sections << toml_section("secrets.archive-kek", {
        "source.inline" => Base64.strict_encode64(
          StorageKeyEncryption.aes256gcm_encrypt(kek_bytes, "archive-kek", archive_kek)
        ),
        "encoding" => "base64",
        "encrypted_by.ref" => "kek"
      })
    end

    sections.join("\n")
  end

  def v2_stripe_source_toml
    if archive?
      return v2_archive_stripe_source_toml
    end

    toml_section("stripe_source", {
      "type" => "raw",
      "image_path" => @image_path,
      "copy_on_read" => @copy_on_read
    })
  end

  def v2_archive_stripe_source_toml
    hash = {
      "type" => "archive",
      "storage" => "s3",
      "bucket" => @archive_params["archive_bucket"],
      "prefix" => @archive_params["archive_prefix"],
      "region" => "auto",
      "endpoint" => @archive_params["archive_endpoint"],
      "connections" => 16,
      "autofetch" => true,
      "access_key_id.ref" => "s3-key-id",
      "secret_access_key.ref" => "s3-secret-key"
    }
    hash["session_token.ref"] = "s3-session-token" if @archive_params["has_session_token"]
    hash["archive_kek.ref"] = "archive-kek" if @archive_params["encrypted"]
    toml_section("stripe_source", hash)
  end

  def toml_section(name, hash)
    "[#{name}]\n#{hash.map { |k, v| "#{k} = #{toml_value(v)}" }.join("\n")}\n"
  end

  def toml_value(v)
    case v
    when String then toml_str(v)
    when Array then "[#{v.map { |e| toml_value(e) }.join(", ")}]"
    else v
    end
  end

  def toml_str(value)
    # From TOML specs:
    # > Basic strings are surrounded by quotation marks ("). Any Unicode
    # > character may be used except those that must be escaped: quotation mark,
    # > backslash, and the control characters other than tab (U+0000 to U+0008,
    # > U+000A to U+001F, U+007F).
    #
    # See https://toml.io/en/v1.0.0#string
    h = {
      "\b" => '\\b',
      "\n" => '\\n',
      "\f" => '\\f',
      "\r" => '\\r',
      '"' => '\\"',
      "\\" => "\\\\"
    }
    h.default_proc = proc { |_, ch| format('\\u%04X', ch.ord) }
    escaped = value.gsub(/[\x00-\x08\x0A-\x1F\x7F"\\]/, h)
    "\"#{escaped}\""
  end

  def vhost_backend_kek(key_wrapping_secrets)
    if use_config_v2?
      # In v2, aes256-gcm nonce (init_vector) is stored as part of the wrapped
      # key, and auth_data is key name, so just pass the base64-encoded
      # aes256-gcm key.
      key_wrapping_secrets["key"]
    else
      {
        "method" => "aes256-gcm",
        "key" => key_wrapping_secrets["key"].strip,
        "init_vector" => key_wrapping_secrets["init_vector"].strip,
        "auth_data" => Base64.strict_encode64(key_wrapping_secrets["auth_data"]).strip
      }.to_yaml
    end
  end

  def write_through_device?
    st = File.stat(disk_file)

    rp = File.realpath("/sys/dev/block/#{st.dev_major}:#{st.dev_minor}")
    dev = File.basename(rp)
    base = File.exist?("/sys/block/#{dev}") ? dev : File.basename(File.dirname(rp))

    File.read("/sys/block/#{base}/queue/write_cache").include?("write through")
  end

  def start(key_wrapping_secrets)
    if @vhost_backend_version
      vhost_backend_start(key_wrapping_secrets)
      return
    end

    encryption_key = read_data_encryption_key(key_wrapping_secrets) if @encrypted
    retries = 0
    begin
      setup_spdk_bdev(encryption_key)
      set_qos_limits
      setup_spdk_vhost
    rescue SpdkExists
      # If some of SPDK artifacts exist, purge and retry. But retry only once
      # to prevent potential retry loops.
      if retries == 0
        retries += 1
        purge_spdk_artifacts
        retry
      end
      raise
    end
  end

  def vhost_backend_start(key_wrapping_secrets)
    # Stop the service in case this is a retry.
    r "systemctl", "stop", vhost_user_block_service

    rm_if_exists(vhost_sock)
    rm_if_exists(sp.rpc_socket_path)

    unless @encrypted
      r "systemctl", "start", vhost_user_block_service
      return
    end

    with_kek_pipe do |kek_pipe|
      r "systemctl", "start", vhost_user_block_service
      write_kek_to_pipe(kek_pipe, vhost_backend_kek(key_wrapping_secrets))
    end
  end

  def with_kek_pipe
    kek_pipe = sp.kek_pipe
    rm_if_exists(kek_pipe)
    File.mkfifo(kek_pipe, 0o600)
    FileUtils.chown @vm_name, @vm_name, kek_pipe
    yield kek_pipe
  ensure
    FileUtils.rm_f(kek_pipe)
  end

  def write_kek_to_pipe(kek_pipe, payload, timeout_sec: KEK_PIPE_WRITE_TIMEOUT_SEC)
    Timeout.timeout(timeout_sec) do
      File.open(kek_pipe, File::WRONLY) do |file|
        file.write(payload)
      end
    end
  end

  def stop_service_if_loaded(name)
    r "systemctl", "stop", name
  rescue CommandFail => e
    raise unless e.stderr.include?("not loaded")
  end

  def purge_spdk_artifacts
    if @vhost_backend_version
      service_file_path = "/etc/systemd/system/#{vhost_user_block_service}"
      stop_service_if_loaded(vhost_user_block_service)
      rm_if_exists(service_file_path)
      rm_if_exists(vhost_sock)
      return
    end

    vhost_controller = SpdkPath.vhost_controller(@vm_name, @disk_index)

    rpc_client.vhost_delete_controller(vhost_controller)

    non_ubi_bdev = @use_bdev_ubi ? "#{@device_id}_base" : @device_id

    if @use_bdev_ubi
      rpc_client.bdev_ubi_delete(@device_id)
    end

    if @encrypted
      rpc_client.bdev_crypto_delete(non_ubi_bdev)
      rpc_client.bdev_aio_delete("#{@device_id}_aio")
      rpc_client.accel_crypto_key_destroy("#{@device_id}_key")
    else
      rpc_client.bdev_aio_delete(non_ubi_bdev)
    end

    rm_if_exists(SpdkPath.vhost_sock(vhost_controller))
  end

  def setup_data_encryption_key(key_wrapping_secrets)
    data_encryption_key = OpenSSL::Cipher.new("aes-256-xts").random_key.unpack1("H*")

    result = {
      cipher: "AES_XTS",
      key: data_encryption_key[..63],
      key2: data_encryption_key[64..]
    }

    key_file = data_encryption_key_path

    # save encrypted key
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.write_encrypted_dek(key_file, result)

    FileUtils.chown @vm_name, @vm_name, key_file
    FileUtils.chmod "u=rw,g=,o=", key_file

    sync_parent_dir(key_file)

    result
  end

  def read_data_encryption_key(key_wrapping_secrets)
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.read_encrypted_dek(data_encryption_key_path)
  end

  def unencrypted_image_copy
    q_image_path = @image_path.shellescape
    q_disk_file = disk_file.shellescape

    r "cp --reflink=auto #{q_image_path} #{q_disk_file}"
    r "truncate -s #{@disk_size_gib}G #{q_disk_file}"

    set_disk_file_permissions
  end

  def verify_imaged_disk_size
    size = File.size(@image_path)
    fail "Image size greater than requested disk size" unless size <= @disk_size_gib * 2**30
  end

  def encrypted_image_copy(encryption_key, input_file, block_size: 2097152, count: nil)
    # Note that spdk_dd doesn't interact with the main spdk process. It is a
    # tool which starts the spdk infra as a separate process, creates bdevs
    # from config, does the copy, and exits. Since it is a separate process
    # for each image, although bdev names are same, they don't conflict.
    # Goal is to copy the image into disk_file, which will be registered
    # in the main spdk daemon after this function returns.

    bdev_conf = [{
      method: "bdev_aio_create",
      params: {
        name: "aio0",
        block_size: 512,
        filename: disk_file,
        readonly: false
      }
    },
      {
        method: "bdev_crypto_create",
        params: {
          base_bdev_name: "aio0",
          name: "crypt0",
          key_name: "super_key"
        }
      }]

    accel_conf = [
      {
        method: "accel_crypto_key_create",
        params: {
          name: "super_key",
          cipher: encryption_key[:cipher],
          key: encryption_key[:key],
          key2: encryption_key[:key2]
        }
      }
    ]

    spdk_config_json = {
      subsystems: [
        {
          subsystem: "accel",
          config: accel_conf
        },
        {
          subsystem: "bdev",
          config: bdev_conf
        }
      ]
    }.to_json

    # spdk_dd uses the same spdk app infra, so it will bind to an rpc socket,
    # which we won't use. But its path shouldn't conflict with other VM setups,
    # so it doesn't error out in concurrent VM creations.
    rpc_socket = "/var/tmp/spdk_dd.sock.#{@vm_name}"

    count_param = count.nil? ? "" : "--count #{count}"

    r("#{SpdkPath.bin(@spdk_version, "spdk_dd")} --config /dev/stdin " \
    "--disable-cpumask-locks " \
    "--rpc-socket #{rpc_socket.shellescape} " \
    "--if #{input_file.shellescape} " \
    "--ob crypt0 " \
    "--bs=#{block_size} #{count_param}", stdin: spdk_config_json)
  end

  def create_ubi_writespace(encryption_key)
    create_empty_disk_file(disk_size_mib: @disk_size_gib * 1024 + 16)
    if @encrypted
      # just clear the metadata section, i.e. first 8MB
      encrypted_image_copy(encryption_key, "/dev/zero", block_size: 2097152, count: 4)
    end
  end

  def create_empty_disk_file(disk_size_mib: @disk_size_gib * 1024)
    FileUtils.touch(disk_file)
    File.truncate(disk_file, disk_size_mib * 1024 * 1024)

    set_disk_file_permissions
  end

  def set_disk_file_permissions
    FileUtils.chown @vm_name, @vm_name, disk_file

    # don't allow others to read user's disk
    FileUtils.chmod "u=rw,g=r,o=", disk_file

    # allow spdk to access the image
    r "setfacl -m u:spdk:rw #{disk_file.shellescape}"
  end

  def setup_spdk_bdev(encryption_key)
    non_ubi_bdev = @use_bdev_ubi ? "#{@device_id}_base" : @device_id

    if encryption_key
      key_name = "#{@device_id}_key"
      aio_bdev = "#{@device_id}_aio"
      rpc_client.accel_crypto_key_create(
        key_name,
        encryption_key[:cipher],
        encryption_key[:key],
        encryption_key[:key2]
      )
      rpc_client.bdev_aio_create(aio_bdev, disk_file, 512)
      rpc_client.bdev_crypto_create(non_ubi_bdev, aio_bdev, key_name)
    else
      rpc_client.bdev_aio_create(non_ubi_bdev, disk_file, 512)
    end

    if @use_bdev_ubi
      rpc_client.bdev_ubi_create(@device_id, non_ubi_bdev, @image_path)
    end
  end

  def set_qos_limits
    return unless @max_read_mbytes_per_sec || @max_write_mbytes_per_sec

    rpc_client.bdev_set_qos_limit(
      @device_id,
      r_mbytes_per_sec: @max_read_mbytes_per_sec,
      w_mbytes_per_sec: @max_write_mbytes_per_sec
    )
  end

  def setup_spdk_vhost
    vhost_controller = SpdkPath.vhost_controller(@vm_name, @disk_index)
    spdk_vhost_sock = SpdkPath.vhost_sock(vhost_controller)

    rpc_client.vhost_create_blk_controller(vhost_controller, @device_id)

    # don't allow others to access the vhost socket
    FileUtils.chmod "u=rw,g=r,o=", spdk_vhost_sock

    # allow vm user to access the vhost socket
    r "setfacl -m u:#{@vm_name}:rw #{spdk_vhost_sock.shellescape}"

    # create a symlink to the socket in the per vm storage dir
    rm_if_exists(vhost_sock)
    FileUtils.ln_s spdk_vhost_sock, vhost_sock

    # Change ownership of the symlink. FileUtils.chown uses File.lchown for
    # symlinks and doesn't follow links. We don't use File.lchown directly
    # because it expects numeric uid & gid, which is less convenient.
    FileUtils.chown @vm_name, @vm_name, vhost_sock

    vhost_sock
  end

  def spdk_service
    @spdk_service ||= SpdkSetup.new(@spdk_version).spdk_service if @spdk_version
  end

  def vhost_user_block_service
    @vhost_user_block_service ||= "#{@vm_name}-#{@disk_index}-storage.service" if @vhost_backend_version
  end

  def q_vhost_user_block_service
    @q_vhost_user_block_service ||= vhost_user_block_service.shellescape if vhost_user_block_service
  end

  def sp
    @sp ||= StoragePath.new(@vm_name, @device, @disk_index)
  end

  def storage_root
    @storage_root ||= sp.storage_root
  end

  def storage_dir
    @storage_dir ||= sp.storage_dir
  end

  def disk_file
    @disk_file ||= sp.disk_file
  end

  def data_encryption_key_path
    @dek_path ||= sp.data_encryption_key
  end

  def vhost_sock
    @vhost_sock ||= sp.vhost_sock
  end

  attr_reader :num_queues

  attr_reader :queue_size
end
