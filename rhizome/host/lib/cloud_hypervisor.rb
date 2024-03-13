# frozen_string_literal: true

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
