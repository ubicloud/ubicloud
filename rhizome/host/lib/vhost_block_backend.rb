# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.4.0-alpha.1" && Arch.x64?
      "847b4979eb699c62a4c729eb93ef30b59bdc01a872c01e06f06e90b703e371d3"
    elsif @version == "v0.4.0-alpha.1" && Arch.arm64?
      "ffda10cea3e140190d372d6f13fe0d176fad9470ad8c8b3654bb18fc16e3c185"
    elsif @version == "v0.3.1" && Arch.x64?
      "3b4a6d3387a8da7c914d85203955c0a879168518aed76679a334070403630262"
    elsif @version == "v0.3.1" && Arch.arm64?
      "d7cd297468569a0fa197d48eb7d21b64aea9598895d1b5b97da8bec5e307d57b"
    elsif @version == "v0.2.1" && Arch.x64?
      "86b29835ead14b20e87a058108a13d9e71243a2e261df144f6e59e2de1e60378"
    elsif @version == "v0.2.1" && Arch.arm64?
      "ebf24fac90411fcc78c9383aabfea3bae9d3df936b667b7c4c0097b0cb4c6357"
    else
      fail "Unsupported version: #{@version}, #{Arch.sym}"
    end
  end

  def url
    "https://github.com/ubicloud/ubiblk/releases/download/#{@version}/vhost-backend-#{Arch.sym}.tar.gz"
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
