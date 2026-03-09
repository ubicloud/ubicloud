# frozen_string_literal: true

require_relative "../../common/lib/util"

class StorageArchive
  def initialize(disk_config_path, disk_kek_path, disk_kek, target_conf, vhost_block_backend_version)
    validate_keys(
      "target_conf",
      %w[bucket prefix region endpoint access_key_id secret_access_key archive_kek],
      %w[session_token],
      target_conf
    )
    @backend = VhostBlockBackend.new(vhost_block_backend_version)
    fail "vhost block backend version #{@backend.version} does not support archive" unless @backend.supports_archive?
    fail "unsupport key encryption algorithm #{disk_kek["algorithm"]}" if disk_kek && disk_kek["algorithm"] != "aes-256-gcm"

    @disk_config_path = disk_config_path
    @disk_kek_path = disk_kek_path
    @disk_kek_b64 = disk_kek["key"] if disk_kek
    @target_conf = target_conf
  end

  def archive
    cmd = [
      @backend.archive_path,
      "--config", @disk_config_path,
      "--target-config", "/dev/stdin",
      "--compression", "zstd",
      "--zstd-level", "3"
    ]
    env = {"RUST_LOG" => "info"}
    target_config = build_target_config
    if @disk_kek_path
      run_with_kek_pipe(
        cmd,
        kek_pipe: @disk_kek_path,
        kek_content: @disk_kek_b64,
        env: env,
        stdin: target_config
      )
    else
      r(*cmd, env: env, stdin: target_config)
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
      "archive_kek.ref" => "archive-kek"
    }
    target["session_token.ref"] = "s3-session-token" if @target_conf["session_token"]

    parts = [toml_section("target", target)]

    parts << toml_section("secrets.s3-key-id", {
      "source.inline" => @target_conf["access_key_id"]
    })
    parts << toml_section("secrets.s3-secret-key", {
      "source.inline" => @target_conf["secret_access_key"]
    })
    parts << toml_section("secrets.archive-kek", {
      "source.inline" => @target_conf["archive_kek"],
      "encoding" => "base64"
    })

    if @target_conf["session_token"]
      parts << toml_section("secrets.s3-session-token", {
        "source.inline" => @target_conf["session_token"]
      })
    end

    # We'll pass the target config using stdin, so using plaintext secrets is
    # acceptable.
    parts << toml_section("danger_zone", {
      "enabled" => true,
      "allow_inline_plaintext_secrets" => true
    })

    parts.join("\n")
  end
end
