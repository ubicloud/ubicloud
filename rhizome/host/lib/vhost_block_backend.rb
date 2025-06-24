# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-6" && Arch.x64?
      "9e7e105e71e9316af40df5a79d6ef1cbbf48dea5d590cf82da60b6a7f99885dc"
    elsif @version == "v0.1-6" && Arch.arm64?
      "f9bce53f07f43e276077735461203ceed000c47554a7fab0fcc64db04bb17452"
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
