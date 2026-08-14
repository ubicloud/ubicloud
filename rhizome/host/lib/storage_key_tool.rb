# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "storage_path"
require_relative "vm_path"
require_relative "storage_volume"
require_relative "vhost_block_backend"
require_relative "../lib/storage_key_encryption"
require "fileutils"
require "json"
require "yaml"
require "base64"

# Rotates the key-encryption-key (KEK) that wraps a storage volume's data
# encryption key (DEK). Only the wrapped DEK is re-wrapped with the new KEK;
# the DEK and on-disk ciphertext are unchanged, so nothing is rewritten and
# rotation takes effect on the next backend start.
#
# The wrapped DEK lives in a different file/format per backend, so the caller
# passes the volume's vhost_block_backend_version and the format is derived
# from it: ""/nil -> spdk, < v0.4.0 -> vhost_legacy, >= v0.4.0 -> vhost_v2.
class StorageKeyTool
  XTS_CIPHER = "AES_XTS"

  # Auxiliary KEK-wrapped secrets a config-v2 volume may carry, by the prep.json
  # source that holds them: source param key => secret name (also the AES-256-GCM
  # auth_data). These are wrapped with the volume KEK just like the DEK, so they
  # must be re-wrapped on rotation too. Kept in sync with the sections
  # StorageVolume#v2_secrets_toml emits.
  WRAPPED_SOURCE_SECRETS = {
    "archive_source" => {
      "encrypted_access_key_id" => "archive-access-key",
      "encrypted_secret_access_key" => "archive-secret-key",
      "encrypted_archive_kek" => "archive-kek",
    },
    "remote_source" => {
      "encrypted_psk" => "remote-psk",
    },
  }.freeze

  def initialize(vm_name, storage_device, disk_index, vhost_block_backend_version)
    @vm_name = vm_name
    @disk_index = disk_index
    @sp = StoragePath.new(vm_name, storage_device, disk_index)
    @format = format_for(vhost_block_backend_version)
    @key_file = key_file
    @new_key_file = "#{@key_file}.new"
  end

  def format_for(version)
    return :spdk if version.nil? || version.empty?
    VhostBlockBackend.new(version).config_v2? ? :vhost_v2 : :vhost_legacy
  end

  def key_file
    case @format
    when :spdk then @sp.data_encryption_key
    when :vhost_v2 then @sp.vhost_backend_secrets_config
    else @sp.vhost_backend_config
    end
  end

  def reencrypt_key_file(old_key, new_key)
    remove_stale_spdk_key_file unless @format == :spdk

    if @format == :vhost_v2
      rewrite_v2_secrets(old_key, new_key)
    else
      write_dek(@new_key_file, new_key, read_dek(@key_file, old_key))
    end
  end

  def test_keys(old_key, new_key)
    old_dek = read_dek(@key_file, old_key)
    new_dek = read_dek(@new_key_file, new_key)

    raise "ciphers don't match" if old_dek[:cipher] != new_dek[:cipher]
    raise "keys don't match" if old_dek[:key] != new_dek[:key]
    raise "second keys don't match" if old_dek[:key2] != new_dek[:key2]
  end

  def retire_old_key
    File.rename @new_key_file, @key_file
    sync_parent_dir(@key_file)
  end

  # For vhost backends data_encryption_key.json is stale, unused key material
  # left by the SPDK->ubiblk migration and by older ubiblk prep (until commit
  # 42a66a114 stopped writing it in the vhost path). Delete it so it can't
  # linger as an out-of-date copy of the key.
  def remove_stale_spdk_key_file
    FileUtils.rm_f(@sp.data_encryption_key)
  end

  private

  # Reads and unwraps the DEK from +file+ with +kek+ as {cipher:, key:, key2:}.
  def read_dek(file, kek)
    case @format
    when :spdk
      StorageKeyEncryption.new(kek).read_encrypted_dek(file)
    when :vhost_legacy
      ke = StorageKeyEncryption.new(kek)
      key1, key2 = YAML.safe_load_file(file).fetch("encryption_key").map { |b64| unwrap_joined(ke, b64) }
      {cipher: XTS_CIPHER, key: key1, key2: key2}
    else # :vhost_v2
      plaintext = v2_unwrap_secret(File.read(file), StorageKeyEncryption::XTS_KEY_NAME, kek)
      {cipher: XTS_CIPHER, key: plaintext[0, 32], key2: plaintext[32, 32]}
    end
  end

  # Re-wraps +dek+ with +kek+ into +file+, preserving the rest of the config
  # (spdk and legacy only; v2 is regenerated in rewrite_v2_secrets).
  def write_dek(file, kek, dek)
    if @format == :spdk
      StorageKeyEncryption.new(kek).write_encrypted_dek(file, dek)
    else # :vhost_legacy
      ke = StorageKeyEncryption.new(kek)
      config = YAML.safe_load_file(@key_file)
      config["encryption_key"] = [wrap_joined(ke, dek[:key]), wrap_joined(ke, dek[:key2])]
      write_file(file, config.to_yaml)
    end
  end

  # Regenerate the config-v2 secrets file with the producer's own writer so the
  # two can't drift. The auxiliary secrets (archive-*, remote-psk) are KEK-wrapped
  # too and must be re-wrapped from the live file, or the config is left
  # half-rotated with secrets the new KEK can't open.
  def rewrite_v2_secrets(old_key, new_key)
    params = volume_params
    text = File.read(@key_file)

    WRAPPED_SOURCE_SECRETS.each do |source_key, secret_names|
      next unless (source = params[source_key])
      secret_names.each do |param_key, name|
        plaintext = v2_unwrap_secret(text, name, old_key)
        source[param_key] = v2_wrap_secret(name, new_key, plaintext)
      end
    end

    xts = v2_unwrap_secret(text, StorageKeyEncryption::XTS_KEY_NAME, old_key)
    encryption_key = {key: xts[0, 32].unpack1("H*"), key2: xts[32, 32].unpack1("H*")}
    write_file(@new_key_file, StorageVolume.new(@vm_name, params).v2_secrets_toml(encryption_key, new_key))
  end

  # The rotating volume's params from prep.json, to rebuild a StorageVolume and
  # to learn whether the volume has an archive source.
  def volume_params
    volumes = JSON.parse(File.read(VmPath.new(@vm_name).prep_json)).fetch("storage_volumes")
    volumes.find { |v| v["disk_index"].to_s == @disk_index.to_s } ||
      fail("no storage volume with disk_index #{@disk_index} in prep.json")
  end

  # Unwrap a config-v2 secret ([secrets.<name>] source.inline, base64) with +kek+.
  def v2_unwrap_secret(text, name, kek)
    StorageKeyEncryption.aes256gcm_decrypt(
      Base64.decode64(kek["key"]), name, Base64.decode64(v2_inline(text, "secrets.#{name}")),
    )
  end

  # Wrap +plaintext+ as a config-v2 secret (base64 of nonce||ct||tag) with +kek+.
  def v2_wrap_secret(name, kek, plaintext)
    Base64.strict_encode64(StorageKeyEncryption.aes256gcm_encrypt(Base64.decode64(kek["key"]), name, plaintext))
  end

  # Legacy stores each wrapped key as Base64(ciphertext || 16-byte tag).
  def unwrap_joined(ke, b64)
    blob = Base64.decode64(b64)
    ke.unwrap_key([blob[0...-16], blob[-16..]])
  end

  def wrap_joined(ke, key_bytes)
    Base64.strict_encode64(ke.wrap_key(key_bytes).join)
  end

  # Extract a section's source.inline from the secrets TOML. There is no TOML
  # parser in the rhizome bundle, so scan the shape our own Toml writer produces
  # and fail loudly if it doesn't match rather than corrupt secrets.
  def v2_inline(text, section)
    in_section = false
    text.each_line do |line|
      if (m = line.match(/^\s*\[([^\]]+)\]\s*$/))
        in_section = (m[1] == section)
      elsif in_section && (m = line.match(/^\s*source\.inline\s*=\s*"([^"]*)"/))
        return m[1]
      end
    end
    fail "no [#{section}] source.inline in #{@key_file}"
  end

  def write_file(path, content)
    File.open(path, "w") {
      _1.write(content)
      fsync_or_fail(_1)
    }
  end
end
