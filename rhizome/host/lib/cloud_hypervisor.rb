# frozen_string_literal: true

require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"

module CloudHypervisor
  FirmwareClassLegacy = Struct.new(:version, :name) {
    def url
      "https://github.com/fdr/edk2/releases/download/#{version}/#{name}"
    end

    def path
      "/opt/fw/#{version}/#{Arch.sym}/#{name}"
    end
  }

  FirmwareClass = Struct.new(:arch, :version) {
    def url
      "https://github.com/ubicloud/build-edk2-firmware/releases/download/edk2-stable#{version}-#{arch}/CLOUDHV-#{arch}.fd"
    end

    def path
      "/opt/fw/CLOUDHV-#{arch}-#{version}.fd"
    end

    def download
      r "curl -L3 -o #{(path + ".tmp").shellescape} #{url.shellescape}"
    end
  }

  NEW_FIRMWARE = FirmwareClass.new(Arch.render, Arch.render(x64: "202402", arm64: "202211"))

  FIRMWARE = if Arch.arm64?
    FirmwareClassLegacy.new("edk2-stable202308", "CLOUDHV_EFI.fd")
  elsif Arch.x64?
    FirmwareClassLegacy.new("edk2-stable202302", "CLOUDHV.fd")
  else
    fail "BUG: unexpected architecture"
  end

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
