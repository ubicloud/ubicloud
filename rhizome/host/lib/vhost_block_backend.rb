# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.3.0" && Arch.x64?
      "4e06ce67edb51d858b6d19da14493cca2f529894941fb8b89a2c53d7faa70dfb"
    elsif @version == "v0.3.0" && Arch.arm64?
      "24e07bb36bbf41bac84a97039f9197938d67ee936806ac3b86452dda004508a3"
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
