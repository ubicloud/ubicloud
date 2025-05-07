# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-3" && Arch.sym == :x64
      "d4093fb4e30f0777e558525de02cb024ee8d72f43a9b8e3e5796922b81eb8f83"
    elsif @version == "v0.1-3" && Arch.sym == :arm64
      "0471cf5e48c5d69938d9330e7bdc9c5edb68076cf88475cd855c6271544e2cac"
    else
      fail "Unsupported version: #{@version}, #{Arch.sym}"
    end
  end

  def url
    "https://github.com/ubicloud/ubiblk/releases/download/#{@version}/vhost-backend-#{Arch.x64? ? "x64" : "arm64"}"
  end

  def dir
    "/opt/vhost-block-backend/#{@version}"
  end

  def bin_path
    "#{dir}/vhost-block-backend"
  end

  def download
    download_file(url, bin_path, sha256)
  end

  def download_file(url, path, sha256)
    return if File.exist?(path)
    FileUtils.mkdir_p(dir)

    safe_write_to_file(path) do |f|
      actual_sha256 = curl_file(url, f.path)
      unless actual_sha256 == sha256
        fail "Invalid SHA-256 digest, expected #{sha256}, got #{actual_sha256}"
      end
    end

    FileUtils.chmod "a+x", path
  end

  def config_path(vm_name, disk_index)
    "/var/storage/#{vm_name}/#{disk_index}/vhost-backend.conf"
  end
end
