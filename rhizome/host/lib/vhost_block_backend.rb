# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class VhostBlockBackend
  def initialize(version)
    @version = version
  end

  def sha256
    if @version == "v0.1-7" && Arch.x64?
      "114119bc78609db3795bcd426a386eb97a623ba78e9177de6b375b9616927ca6"
    elsif @version == "v0.1-7" && Arch.arm64?
      "aa92b91130de6e086332c4ad8dcb76e233624055532d5494db0a987883adee0f"
    elsif @version == "v0.2.0" && Arch.x64?
      "68638b779a227424cbe81674de4b26122ea27a337f1c6d81db895a1ffa3a917a"
    elsif @version == "v0.2.0" && Arch.arm64?
      "6b15ca96cd3134524a639d3c913b43b794423a8dddc897c1604a5085625d44e3"
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

  def remove
    FileUtils.rm_rf(dir)
  end
end
