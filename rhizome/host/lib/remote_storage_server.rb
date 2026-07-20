# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/util"
# base64/yaml must be required after util.rb runs bundler/setup, so the bundled
# gem versions win over the default gems.
require "yaml"
require "base64"
require_relative "storage_path"
require_relative "vhost_block_backend"
require_relative "kek_pipe"
require_relative "toml"

# Serves an existing (encrypted) storage volume over the ubiblk remote stripe
# protocol with TLS-PSK. The server always runs the v0.5.0 remote-stripe-server
# binary, which can serve volumes created by older backends: current-format
# (v0.4.0+) volumes directly, and legacy v0.2.x volumes via --legacy. It reuses
# the volume's own vhost-backend config (data/metadata/encryption and, if any,
# its stripe source), adding only a listen config for the address + PSK. The
# KEK is streamed to the volume's kek pipe, exactly as the vhost backend
# receives it.
class RemoteStorageServer
  include Toml
  include KekPipe

  def initialize(vm_name, storage_device, disk_index, source_version, server_version)
    @vm_name = vm_name
    @sp = StoragePath.new(vm_name, storage_device, disk_index)
    @source_backend = VhostBlockBackend.new(source_version)
    @server_backend = VhostBlockBackend.new(server_version)
  end

  # A legacy (v0.2.x) source uses the old YAML config and needs --legacy.
  def legacy?
    !@source_backend.config_v2?
  end

  def listen_config_path
    @listen_config_path ||= File.join(@sp.storage_dir, "remote-stripe-listen.conf")
  end

  def listen_config(port, psk, psk_identity)
    [
      toml_section("server", {"address" => "0.0.0.0:#{port}"}),
      toml_section("server.psk", {"identity" => psk_identity, "secret.ref" => "psk"}),
      toml_section("secrets.psk", {"source.inline" => psk, "encoding" => "base64"}),
      toml_section("danger_zone", {"enabled" => true, "allow_inline_plaintext_secrets" => true})
    ].join("\n")
  end

  def write_listen_config(port, psk, psk_identity)
    File.write(listen_config_path, listen_config(port, psk, psk_identity))
    File.chmod(0o600, listen_config_path)
  end

  # Format the KEK exactly as the source volume's backend expects it: a v2
  # backend reads the base64 aes-256-gcm key from the pipe, while v0.2.x expects
  # the YAML key-encryption-cipher (--legacy-kek) with method/key/iv/auth_data.
  def kek_payload(kek_material)
    if legacy?
      {
        "method" => "aes256-gcm",
        "key" => kek_material.fetch("key").strip,
        "init_vector" => kek_material.fetch("init_vector").strip,
        "auth_data" => Base64.strict_encode64(kek_material.fetch("auth_data")).strip
      }.to_yaml
    else
      kek_material.fetch("key")
    end
  end

  # Run the remote-stripe-server daemon in the foreground (this process becomes
  # the server). A forked writer streams the KEK to the volume's kek pipe, which
  # the server reads once at startup, then this process is replaced by the
  # server. Serving a volume whose VM is running is not supported (the vhost
  # backend already owns the disk and the kek pipe).
  def run(port, psk, psk_identity, kek_material)
    fail "remote-stripe-server requires vhost block backend v0.5.0 or later" unless @server_backend.supports_remote_stripe_server?
    write_listen_config(port, psk, psk_identity)

    rm_if_exists(@sp.kek_pipe)
    File.mkfifo(@sp.kek_pipe, 0o600)
    FileUtils.chown @vm_name, @vm_name, @sp.kek_pipe
    writer = fork { write_kek_to_pipe(@sp.kek_pipe, kek_payload(kek_material), timeout_sec: 60) }
    Process.detach(writer)

    args = [@server_backend.remote_stripe_server_path, "-f", @sp.vhost_backend_config]
    args += ["--legacy", "--legacy-kek", @sp.kek_pipe] if legacy?
    args += ["--listen-config", listen_config_path]
    exec({"RUST_LOG" => "info"}, *args)
  end
end
