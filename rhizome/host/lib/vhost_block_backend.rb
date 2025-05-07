# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-2" && Arch.sym == :x64
      "3cbb2b378c455cfd006bc2aedde8cfd786b8233a78441700043fb1da9d794996"
    elsif @version == "v0.1-2" && Arch.sym == :arm64
      "c0ce4d4dbcb60bd1b5e024469250c788bb581e80f1f9a82f6998018c4c38280c"
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
