# frozen_string_literal: true

require_relative "../../common/lib/util"


class StripeServer
  def initialize(params)
    @vhost_backend_version = params["vhost_block_backend_version"]
    @device = params["storage_device"] || DEFAULT_STORAGE_DEVICE
    @persistent_volume_name = params["persistent_volume_name"]
    @psk_identity = params["psk_identity"]
    @psk_secret = params["psk_secret"]
    @address = params["address"]
  end

  def prep(key_encryption_key)
    config = stripe_server_config
    File.write(sp.stripe_server_config, JSON.pretty_generate(config))

    create_service_file
  end

  def start(key_encryption_key)
    q_service = service_file_name.shellescape

    # Stop the service in case this is a retry.
    r "systemctl stop #{q_service}"

    begin
      kek_pip = sp.kek_pipe
      rm_if_exists(kek_pip)
      File.mkfifo(kek_pip, 0o600)

      r "systemctl start #{q_service}"

      Timeout.timeout(5) do
        kek_yaml = kek_config(key_wrapping_secrets).to_yaml
        File.write(kek_pip, kek_yaml)
      end
    ensure
      rm_if_exists(kek_pip)
    end
  end

  def purge
    q_service = service_file_name.shellescape
    r "systemctl stop #{q_service}"
    r "systemctl disable #{q_service}"
    rm_if_exists("/etc/systemd/system/#{service_file_name}")
  end

  def service_file_name
    "stripe-server-#{@persistent_volume_name}.service"
  end

  def kek_config(key_wrapping_secrets)
    {
      "method" => "aes256-gcm",
      "key" => key_wrapping_secrets["key"].strip,
      "init_vector" => key_wrapping_secrets["init_vector"].strip,
      "auth_data" => Base64.strict_encode64(key_wrapping_secrets["auth_data"]).strip
    }
  end

  def create_service_file
    vhost_backend = VhostBlockBackend.new(@vhost_backend_version)
    service_file_path = "/etc/systemd/system/#{service_file_name}"
    kek_arg = "--kek #{sp.kek_pipe}"
    File.write(service_file_path, <<~SERVICE)
        [Unit]
        Description=Stripe Server Service for #{@persistent_volume_name}
        After=network.target

        [Service]
        Environment=RUST_LOG=info
        Environment=RUST_BACKTRACE=1
        ExecStart=#{vhost_backend.stripe_server_path} --config #{sp.stripe_server_config} #{kek_arg}
        Restart=always
        User=root
        Group=root

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
        ReadWritePaths=#{sp.storage_dir}
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
        
        RestrictAddressFamilies=AF_UNIX
        RestrictNamespaces=true
        SystemCallArchitectures=native
        SystemCallFilter=@system-service

        MemoryDenyWriteExecute=yes
        RestrictSUIDSGID=yes
        RestrictRealtime=yes
        ProcSubset=pid
        PrivateNetwork=yes
        PrivateUsers=yes
        IPAddressDeny=any

        [Install]
        WantedBy=multi-user.target
    SERVICE
  end

  def stripe_server_config
    {
      address: @address,
      psk_identity: @psk_identity,
      psk_secret: wrap_key_b64(
        StorageKeyEncryption.new(key_encryption_key),
        @psk_secret
      )
    }
  end

  def wrap_key_b64(key_encryption, key)
    wrapped_key = key_encryption.wrap_key(key)
    Util.encode_base64(wrapped_key)
  end

  def sp
    @sp ||= StoragePath.new(nil, @device, nil, @persistent_volume_name)
  end
end