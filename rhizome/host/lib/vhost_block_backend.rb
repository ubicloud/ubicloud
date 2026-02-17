# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.4.0" && Arch.x64?
      "c74f1d4bef624d5f46e3763d6d63ac79ca3e8f3fccd1696840266398834d53d0"
    elsif @version == "v0.4.0" && Arch.arm64?
      "65dd7354b087a07fca7d35bca00014532fd636e7aae838e32d87ee0d37284fad"
    elsif @version == "v0.3.1" && Arch.x64?
      "3b4a6d3387a8da7c914d85203955c0a879168518aed76679a334070403630262"
    elsif @version == "v0.3.1" && Arch.arm64?
      "d7cd297468569a0fa197d48eb7d21b64aea9598895d1b5b97da8bec5e307d57b"
    elsif @version == "v0.2.2" && Arch.x64?
      "f5b7b2b88fa18e5070ff319b15363aed671e496d9f6cccec3bbcc48a6f38a44a"
    elsif @version == "v0.2.2" && Arch.arm64?
      "7f4a5818fdab4e7524855096352d9ceaa038ff254de2b52c88d491f76a05686f"
    else
      fail "Unsupported version: #{@version}, #{Arch.sym}"
    end
  end

  def url
    legacy_version = Gem::Version.new(@version.delete_prefix("v")) < Gem::Version.new("0.4.0")
    if legacy_version
      "https://github.com/ubicloud/ubiblk/releases/download/#{@version}/vhost-backend-#{Arch.sym}.tar.gz"
    else
      "https://github.com/ubicloud/ubiblk/releases/download/#{@version}/ubiblk-#{Arch.sym}.tar.gz"
    end
  end

  def dir
    "/opt/vhost-block-backend/#{@version}"
  end

  def bin_path
    "#{dir}/vhost-backend"
  end

  def init_metadata_path
    "#{dir}/init-metadata"
  end

  def download
    temp_tarball = "/tmp/vhost-backend-#{@version}.tar.gz"
    puts "Downloading ubiblk package from #{url}"
    r "curl -L3 --connect-timeout 5 --max-time 30 -o #{temp_tarball} #{url}"
    FileUtils.mkdir_p(dir)
    FileUtils.cd dir do
      r "tar -xzf #{temp_tarball}"
    end
    FileUtils.rm_f temp_tarball
  end
end
