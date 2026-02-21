# frozen_string_literal: true

require_relative "storage_key_encryption"

# Generates ubiblk config v2 (TOML) for vhost-backend >= 0.4.0.
#
# Config is split into layered files joined by the include directive:
# - Main config: device, tuning, encryption, include directives
# - Stripe source config: archive/remote stripe source details
# - Secrets config: secret definitions (XTS keys, KEKs)
#
# Encryption method logic (cipher selection, key wrapping) lives in
# StorageKeyEncryption.
class VhostBackendConfigV2
  def initialize(params)
    @disk_file = params[:disk_file]
    @vhost_sock = params[:vhost_sock]
    @rpc_socket_path = params[:rpc_socket_path]
    @device_id = params[:device_id]
    @num_queues = params[:num_queues]
    @queue_size = params[:queue_size]
    @copy_on_read = params[:copy_on_read] || false
    @write_through = params[:write_through] || false
    @skip_sync = params[:skip_sync] || false
    @image_path = params[:image_path]
    @metadata_path = params[:metadata_path]
    @cpus = params[:cpus]
    @encrypted = params[:encrypted] || false
    @encryption_key = params[:encryption_key]
    @key_wrapping_secrets = params[:kek]
    @kek_pipe = params[:kek_pipe]
    @stripe_source_config_path = params[:stripe_source_config_path]
    @secrets_config_path = params[:secrets_config_path]

    # Archive stripe source params (for machine image-backed volumes)
    @archive_params = params[:archive_params]
    @archive_kek_pipe = params[:archive_kek_pipe]
    @s3_access_key = params[:s3_access_key]
    @s3_secret_key = params[:s3_secret_key]
  end

  def archive?
    !@archive_params.nil?
  end

  # Generate the main config TOML with include directives.
  def main_toml
    sections = []
    sections << include_section
    sections << device_section
    sections << tuning_section
    sections << ske.v2_encryption_toml if @encrypted
    sections.join("\n")
  end

  # Generate the stripe source config TOML.
  def stripe_source_toml
    return stripe_source_section if archive?
    return nil unless @image_path
    stripe_source_section
  end

  # Generate the secrets config TOML.
  def secrets_toml
    parts = []
    parts << ske.v2_secrets_toml(@encryption_key, @kek_pipe) if @encrypted
    parts << archive_secrets_toml if archive?
    return nil if parts.empty?
    parts.join("\n")
  end

  # Return the raw 32-byte KEK for writing to the pipe.
  def kek_bytes
    ske.kek_bytes
  end

  private

  def ske
    @ske ||= StorageKeyEncryption.new(@key_wrapping_secrets)
  end

  def has_stripe_source?
    archive? || @image_path
  end

  def has_secrets?
    @encrypted || archive?
  end

  def include_section
    includes = []
    includes << File.basename(@stripe_source_config_path) if has_stripe_source? && @stripe_source_config_path
    includes << File.basename(@secrets_config_path) if has_secrets? && @secrets_config_path
    return "" if includes.empty?

    items = includes.map { |f| toml_str(f) }.join(", ")
    "include = [#{items}]\n"
  end

  def device_section
    lines = ["[device]"]
    lines << "data_path = #{toml_str(@disk_file)}"
    lines << "metadata_path = #{toml_str(@metadata_path)}" if @metadata_path
    lines << "vhost_socket = #{toml_str(@vhost_sock)}"
    lines << "rpc_socket = #{toml_str(@rpc_socket_path)}"
    lines << "device_id = #{toml_str(@device_id)}"
    lines << "track_written = true"
    lines.join("\n") + "\n"
  end

  def tuning_section
    lines = ["[tuning]"]
    lines << "num_queues = #{@num_queues}"
    lines << "queue_size = #{@queue_size}"
    lines << "seg_size_max = #{64 * 1024}"
    lines << "seg_count_max = 4"
    lines << "poll_timeout_us = 1000"
    lines << "write_through = #{@write_through}"
    lines << "cpus = [#{@cpus.join(", ")}]" if @cpus
    lines.join("\n") + "\n"
  end

  def stripe_source_section
    if archive?
      archive_stripe_source_section
    else
      raw_stripe_source_section
    end
  end

  def raw_stripe_source_section
    lines = ["[stripe_source]"]
    lines << "type = \"raw\""
    lines << "image_path = #{toml_str(@image_path)}"
    lines << "copy_on_read = #{@copy_on_read}"
    lines.join("\n") + "\n"
  end

  def archive_stripe_source_section
    lines = ["[stripe_source]"]
    lines << "type = \"archive\""
    lines << "storage = \"s3\""
    lines << "bucket = #{toml_str(@archive_params["archive_bucket"])}"
    lines << "prefix = #{toml_str(@archive_params["archive_prefix"])}"
    lines << "region = \"auto\""
    lines << "endpoint = #{toml_str(@archive_params["archive_endpoint"])}"
    lines << "connections = 16"
    lines << "autofetch = true"
    lines << 'access_key_id.ref = "s3-key-id"'
    lines << 'secret_access_key.ref = "s3-secret-key"'
    lines << 'archive_kek.ref = "archive-kek"' if @archive_params["encrypted"]
    lines.join("\n") + "\n"
  end

  def archive_secrets_toml
    lines = []

    lines << "[secrets.s3-key-id]"
    lines << "source.inline = #{toml_str(@s3_access_key)}"
    lines << ""

    lines << "[secrets.s3-secret-key]"
    lines << "source.inline = #{toml_str(@s3_secret_key)}"
    lines << ""

    if @archive_params["encrypted"]
      lines << "[secrets.archive-kek]"
      lines << "source.file = #{toml_str(@archive_kek_pipe)}"
      lines << 'encoding = "base64"'
      lines << ""
    end

    lines.join("\n") + "\n"
  end

  def toml_str(value)
    "\"#{value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
  end
end
