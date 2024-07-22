# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

module CloudHypervisor
  FirmwareClass = Struct.new(:version, :sha256) {
    def url
      "https://github.com/ubicloud/build-edk2-firmware/releases/download/edk2-stable#{version}-#{Arch.sym}/CLOUDHV-#{Arch.sym}.fd"
    end

    def firmware_root
      "/opt/fw"
    end

    def path
      "#{firmware_root}/CLOUDHV-#{version}.fd"
    end

    def download
      return if File.exist?(path)
      FileUtils.mkdir_p(firmware_root)
      sha256_curl = nil
      safe_write_to_file(path) do |f|
        sha256_curl = curl_file(url, f.path)
        fail "Invalid SHA-256 digest" unless sha256 == sha256_curl
      end
      sha256_curl
    end
  }

  FIRMWARE = FirmwareClass.new(Arch.render(x64: "202311", arm64: "202211"),
    Arch.render(x64: "e31738aacd3d68d30f8f9a4d09711cca3dfb414e8910dc3af90c50f36885380a", arm64: "482f428f782591d7c2222e0bc8240d25fb200fb21fd984b3339c85979d94b4d8"))

  VersionClass = Struct.new(:version, :sha256_ch_bin, :sha256_ch_remote) {
    def ch_remote_url
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/ch-remote" + Arch.render(x64: "-static", arm64: "-static-aarch64")
    end

    def cloud_hypervisor_url
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/cloud-hypervisor" + Arch.render(x64: "-static", arm64: "-static-aarch64")
    end

    def dir
      "/opt/cloud-hypervisor/v#{version}"
    end

    def ch_remote_bin
      File.join(dir, "ch-remote")
    end

    def bin
      File.join(dir, "cloud-hypervisor")
    end

    def download
      download_file(ch_remote_url, ch_remote_bin, sha256_ch_remote)
      download_file(cloud_hypervisor_url, bin, sha256_ch_bin)
    end

    def download_file(url, path, sha256)
      return if File.exist?(path)
      FileUtils.mkdir_p(dir)
      sha256_curl = nil
      safe_write_to_file(path) do |f|
        sha256_curl = curl_file(url, f.path)
        fail "Invalid SHA-256 digest" unless sha256 == sha256_curl
      end
      FileUtils.chmod "a+x", path
    end
  }

  VERSION = if Arch.arm64?
    VersionClass.new("35.1", "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606", "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249")
  elsif Arch.x64?
    VersionClass.new("35.1", "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4", "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0")
  end
end
