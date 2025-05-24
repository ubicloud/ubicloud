# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-4" && Arch.sym == :x64
      "b0cfa320f2ee4f9b22575b6199d02246c989d632566dce4c51ad4db0f19e62a0"
    elsif @version == "v0.1-4" && Arch.sym == :arm64
      "bfe97f5e586a1d05124c808a5534296048ba1d02141723933c556c241d13564e"
    else
      fail "Unsupported version: #{@version}, #{Arch.sym}"
    end
  end

  def url
    "https://github.com/ubicloud/ubiblk/releases/download/#{@version}/vhost-backend-#{Arch.x64? ? "x64" : "arm64"}.tar.gz"
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
    r "curl -L3 -o #{temp_tarball} #{url}"
    FileUtils.mkdir_p(dir)
    FileUtils.cd dir do
      r "tar -xzf #{temp_tarball}"
    end
    FileUtils.rm_f temp_tarball
  end

  def config_path(vm_name, disk_index)
    "/var/storage/#{vm_name}/#{disk_index}/vhost-backend.conf"
  end

  def metadata_path(vm_name, disk_index)
    "/var/storage/#{vm_name}/#{disk_index}/metadata"
  end
end
