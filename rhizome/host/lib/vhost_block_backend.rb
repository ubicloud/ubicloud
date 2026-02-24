# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"

class VhostBlockBackend
  SHA256_BY_VERSION_AND_ARCH = {
    ["v0.4.0", :x64] => "c74f1d4bef624d5f46e3763d6d63ac79ca3e8f3fccd1696840266398834d53d0",
    ["v0.4.0", :arm64] => "65dd7354b087a07fca7d35bca00014532fd636e7aae838e32d87ee0d37284fad",
    ["v0.3.1", :x64] => "3b4a6d3387a8da7c914d85203955c0a879168518aed76679a334070403630262",
    ["v0.3.1", :arm64] => "d7cd297468569a0fa197d48eb7d21b64aea9598895d1b5b97da8bec5e307d57b",
    ["v0.2.2", :x64] => "f5b7b2b88fa18e5070ff319b15363aed671e496d9f6cccec3bbcc48a6f38a44a",
    ["v0.2.2", :arm64] => "7f4a5818fdab4e7524855096352d9ceaa038ff254de2b52c88d491f76a05686f"
  }.freeze

  SHA256_BY_VERSION_AND_ARCH.each_key(&:freeze)

  def initialize(version)
    @version = version
    @v0_4_or_later = Gem::Version.new(version.delete_prefix("v")) >= Gem::Version.new("0.4.0")
  end

  def config_v2?
    @v0_4_or_later
  end

  def sha256
    SHA256_BY_VERSION_AND_ARCH.fetch([@version, Arch.sym]) do
      fail "Unsupported version: #{@version}, #{Arch.sym}"
    end
  end

  def url
    dir = "https://github.com/ubicloud/ubiblk/releases/download/#{@version}"
    if @v0_4_or_later
      "#{dir}/ubiblk-#{Arch.sym}.tar.gz"
    else
      "#{dir}/vhost-backend-#{Arch.sym}.tar.gz"
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
    downloaded_sha256 = curl_file(url, temp_tarball)
    fail "Invalid SHA-256 digest" unless downloaded_sha256 == sha256
    FileUtils.mkdir_p(dir)
    FileUtils.cd dir do
      r "tar -xzf #{temp_tarball}"
    end
    FileUtils.rm_f temp_tarball
  end
end
