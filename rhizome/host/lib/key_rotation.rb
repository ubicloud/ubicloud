# frozen_string_literal: true

require "base64"
require "openssl"
require "perfect_toml"
require "yaml"
require_relative "../../common/lib/util"
require_relative "storage_key_encryption"
require_relative "storage_path"
require_relative "vhost_block_backend"

class KeyRotation
  FORMATS = [:spdk, :config_v1, :config_v2].freeze

  attr_reader :path, :file_format, :user, :stale_spdk_key

  def self.build_from_vm(vm_name, params)
    sp = StoragePath.new(vm_name, params["storage_device"] || DEFAULT_STORAGE_DEVICE, params["disk_index"])
    version = params["vhost_block_backend_version"]
    if version.nil?
      new(sp.data_encryption_key, :spdk, vm_name)
    elsif VhostBlockBackend.new(version).config_v2?
      new(sp.vhost_backend_secrets_config, :config_v2, vm_name, stale_spdk_key: sp.data_encryption_key)
    else
      new(sp.vhost_backend_config, :config_v1, vm_name, stale_spdk_key: sp.data_encryption_key)
    end
  end

  def initialize(path, file_format, user, stale_spdk_key: nil)
    fail "unknown key file format: #{file_format}" unless FORMATS.include?(file_format)

    @path = path
    @file_format = file_format
    @user = user
    @stale_spdk_key = stale_spdk_key
  end

  def backup(old_kek)
    write_file(backup_path(old_kek), File.read(@path))
  end

  def rotate(old_kek, new_kek)
    remove_stale_spdk_key
    source = backup_path(old_kek)
    new = "#{@path}.new"

    write_file(new, rewrap(source, old_kek, new_kek))
    verify(source, old_kek, new, new_kek)
    File.rename(new, @path)
    sync_parent_dir(@path)
  end

  def retire_backup(old_kek)
    path = backup_path(old_kek)
    rm_if_exists(path)
    sync_parent_dir(path)
  end

  def backup_path(kek)
    "#{@path}.#{OpenSSL::Digest::SHA256.hexdigest(kek["key"])}"
  end

  def verify(source, old_kek, new, new_kek)
    fail "secrets changed after rotation" unless plaintexts(source, old_kek) == plaintexts(new, new_kek)
  end

  def rewrap(source, old_kek, new_kek)
    case @file_format
    when :spdk then rewrap_spdk(source, old_kek, new_kek)
    when :config_v1 then rewrap_v1(source, old_kek, new_kek)
    else rewrap_v2(source, old_kek, new_kek)
    end
  end

  def plaintexts(path, kek)
    case @file_format
    when :spdk then read_dek_spdk(path, kek)
    when :config_v1 then read_dek_v1(path, kek)
    else secrets_v2(path, kek)
    end
  end

  def rewrap_spdk(source, old_kek, new_kek)
    StorageKeyEncryption.new(new_kek).encrypted_dek_json(read_dek_spdk(source, old_kek))
  end

  def read_dek_spdk(path, kek)
    StorageKeyEncryption.new(kek).read_encrypted_dek(path)
  end

  def rewrap_v1(source, old_kek, new_kek)
    dek = read_dek_v1(source, old_kek)
    ke = StorageKeyEncryption.new(new_kek)
    config = YAML.safe_load_file(source)
    config["encryption_key"] = [ke.wrap_key_b64(dek[:key]), ke.wrap_key_b64(dek[:key2])]
    config.to_yaml
  end

  def read_dek_v1(path, kek)
    ke = StorageKeyEncryption.new(kek)
    key1, key2 = YAML.safe_load_file(path).fetch("encryption_key").map { |b64| ke.unwrap_key_b64(b64) }
    {cipher: "AES_XTS", key: key1, key2: key2}
  end

  def rewrap_v2(source, old_kek, new_kek)
    old_key = Base64.decode64(old_kek["key"])
    new_key = Base64.decode64(new_kek["key"])
    config = PerfectTOML.load_file(source)
    config.fetch("secrets").each do |name, secret|
      next if name == "kek"

      plaintext = unwrap_secret_v2(name, secret, old_key)
      secret["source"]["inline"] = Base64.strict_encode64(StorageKeyEncryption.aes256gcm_encrypt(new_key, name, plaintext))
    end
    PerfectTOML.generate(config)
  end

  def secrets_v2(path, kek)
    key = Base64.decode64(kek["key"])
    PerfectTOML.load_file(path).fetch("secrets").filter_map { |name, secret|
      [name, unwrap_secret_v2(name, secret, key)] unless name == "kek"
    }.to_h
  end

  def unwrap_secret_v2(name, secret, kek_key)
    fail "config-v2 secret #{name} is not wrapped by the kek" unless secret.dig("encrypted_by", "ref") == "kek"
    fail "config-v2 secret #{name} is not base64 encoded" unless secret["encoding"] == "base64"
    inline = secret.dig("source", "inline")
    fail "config-v2 secret #{name} has no inline value" unless inline
    StorageKeyEncryption.aes256gcm_decrypt(kek_key, name, Base64.strict_decode64(inline))
  end

  def remove_stale_spdk_key
    return unless @stale_spdk_key && File.exist?(@stale_spdk_key)

    rm_if_exists(@stale_spdk_key)
    sync_parent_dir(@stale_spdk_key)
  end

  def write_file(path, content)
    safe_write_to_file(path, perm: 0o600, owner: @user) do |file|
      file.write(content)
      fsync_or_fail(file)
    end

    sync_parent_dir(path)
  end
end
