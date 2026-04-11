# frozen_string_literal: true

require "tmpdir"
require_relative "../../common/lib/util"
require_relative "boot_image"
require_relative "kek_pipe"
require_relative "toml"
require_relative "vhost_block_backend"

class StorageArchive
  include KekPipe
  include Toml
  extend Toml

  def initialize(disk_config_path, disk_kek_path, disk_kek, target_conf, vhost_block_backend_version, stats_file)
    validate_keys(
      "target_conf",
      %w[bucket prefix region endpoint access_key_id secret_access_key archive_kek],
      %w[session_token],
      target_conf,
    )
    @backend = VhostBlockBackend.new(vhost_block_backend_version)

    fail "vhost block backend version #{vhost_block_backend_version} does not support archive" unless @backend.supports_archive?
    fail "disk KEK provided without path" if disk_kek && !disk_kek_path
    fail "disk KEK path provided without KEK" if disk_kek_path && !disk_kek
    StorageArchive.verify_key_encryption_key(disk_kek, "disk_kek") if disk_kek
    StorageArchive.verify_key_encryption_key(target_conf["archive_kek"], "target_conf archive_kek")

    @disk_config_path = disk_config_path
    @disk_kek_path = disk_kek_path
    @disk_kek = disk_kek
    @target_conf = target_conf
    @stats_file = stats_file
  end

  def self.archive_url(url, sha256sum, target_conf, vhost_block_backend_version, stats_file)
    Dir.mktmpdir do |dir|
      # download the image and convert it to raw format.
      boot_image = BootImage.new("image", nil, image_root: dir)
      boot_image.download(url: url, sha256sum: sha256sum)

      # setup a disk with the image as the stripe source
      disk_raw_path = File.join(dir, "disk.raw")
      image_size = File.size(boot_image.image_path)
      image_size_mib = (image_size/1048576r).ceil
      r "truncate", "-s", "#{image_size_mib}M", disk_raw_path

      config_path = File.join(dir, "vhost-backend.conf")
      safe_write_to_file(config_path, [
        toml_section("device", {"data_path" => disk_raw_path, "metadata_path" => File.join(dir, "metadata")}),
        toml_section("stripe_source", {"type" => "raw", "image_path" => boot_image.image_path}),
        toml_section("danger_zone", {"enabled" => true, "allow_unencrypted_disk" => true}),
      ].join("\n"))

      vp = VhostBlockBackend.new(vhost_block_backend_version)
      r({"RUST_LOG" => "info"}, vp.init_metadata_path, "--config", config_path)

      # archive
      StorageArchive.new(config_path, nil, nil, target_conf, vhost_block_backend_version, stats_file).archive
    end
  end

  def archive
    cmd = [
      @backend.archive_path,
      "--config", @disk_config_path,
      "--target-config", "/dev/stdin",
      "--compression", "zstd",
      "--zstd-level", "3",
      "--stats", @stats_file,
    ]
    env = {"RUST_LOG" => "info"}
    target_config = build_target_config
    if @disk_kek_path
      run_with_kek_pipe(
        cmd,
        kek_pipe: @disk_kek_path,
        kek_content: @disk_kek["key"],
        env: env,
        stdin: target_config,
      )
    else
      r(env, *cmd, stdin: target_config)
    end
  end

  def build_target_config
    target = {
      "storage" => "s3",
      "bucket" => @target_conf["bucket"],
      "prefix" => @target_conf["prefix"],
      "region" => @target_conf["region"],
      "endpoint" => @target_conf["endpoint"],
      "access_key_id.ref" => "s3-key-id",
      "secret_access_key.ref" => "s3-secret-key",
      "archive_kek.ref" => "archive-kek",
    }
    target["session_token.ref"] = "s3-session-token" if @target_conf["session_token"]

    parts = [toml_section("target", target)]

    parts << toml_section("secrets.s3-key-id", {
      "source.inline" => @target_conf["access_key_id"],
    })
    parts << toml_section("secrets.s3-secret-key", {
      "source.inline" => @target_conf["secret_access_key"],
    })
    parts << toml_section("secrets.archive-kek", {
      "source.inline" => @target_conf["archive_kek"]["key"],
      "encoding" => "base64",
    })

    if @target_conf["session_token"]
      parts << toml_section("secrets.s3-session-token", {
        "source.inline" => @target_conf["session_token"],
      })
    end

    # We'll pass the target config using stdin, so using plaintext secrets is
    # acceptable.
    parts << toml_section("danger_zone", {
      "enabled" => true,
      "allow_inline_plaintext_secrets" => true,
    })

    parts.join("\n")
  end

  def self.verify_key_encryption_key(kek, context)
    fail "unsupported key encryption algorithm #{kek["algorithm"]} for #{context}" if kek["algorithm"] != "aes-256-gcm"
    fail "missing key for #{context}" unless kek["key"]
  end
end
