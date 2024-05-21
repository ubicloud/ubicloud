# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

module CloudHypervisor
  FirmwareClassLegacy = Struct.new(:version, :name) {
    def url
      "https://github.com/fdr/edk2/releases/download/#{version}/#{name}"
    end

    def path
      "/opt/fw/#{version}/#{Arch.sym}/#{name}"
    end
  }

  FIRMWARE = if Arch.arm64?
    FirmwareClassLegacy.new("edk2-stable202308", "CLOUDHV_EFI.fd")
  elsif Arch.x64?
    FirmwareClassLegacy.new("edk2-stable202302", "CLOUDHV.fd")
  else
    fail "BUG: unexpected architecture"
  end

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
        sha256_curl = curl_firmware(f)
        fail "Invalid SHA-256 digest" unless sha256 == sha256_curl
      end
      sha256_curl
    end

    def curl_firmware(file)
      r("bash -c 'curl -f -L3 #{url.shellescape} | tee >(openssl dgst -sha256) > #{file.path.shellescape}'").split(" ").last
    end
  }

  NEW_FIRMWARE = FirmwareClass.new(Arch.render(x64: "202402", arm64: "202211"),
    Arch.render(x64: "2cf0e7bd7164cbe1d353ccfe176f41e57b8036492eb7b0a94f9b04c0c973764d", arm64: "3e34934478870a2ce67eb76bef6f9f38eb6a8b16849115b64473f05c2ccb922a"))

  VersionClass = Struct.new(:version) {
    def ch_remote_url
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/ch-remote" + Arch.render(x64: "", arm64: "-static-aarch64")
    end

    def url
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/cloud-hypervisor" + Arch.render(x64: "", arm64: "-static-aarch64")
    end

    def dir
      "/opt/cloud-hypervisor/v#{version}"
    end

    def bin
      File.join(dir, "cloud-hypervisor")
    end

    def ch_remote_bin
      File.join(dir, "ch-remote")
    end
  }

  VERSION = if Arch.arm64?
    VersionClass.new("35.0")
  elsif Arch.x64?
    VersionClass.new("31.0")
  else
    fail "BUG: unexpected architecture"
  end
end
