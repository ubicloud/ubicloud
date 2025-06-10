# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-5" && Arch.x64?
      "f34de686dd7d1d7fcc26ba6ab593e81253600195610823ab1c61f603f337c6cc"
    elsif @version == "v0.1-5" && Arch.arm64?
      "ee6298fa0024aa15543dfa7fd6f2f6795ab15db3134ea14ae44803c07d3a35ee"
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
