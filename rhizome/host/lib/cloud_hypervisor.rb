# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

module CloudHypervisor
  # For Firmware and Version:
  #
  # SUPPORTED constant is a hash of versions that should be installed by prep_host
  # INSTALLED constant is a hash of versions that are installed, with a default of the default version

  class Firmware < Struct.new(:version, :sha256)
    def url
      "https://github.com/ubicloud/build-edk2-firmware/releases/download/edk2-stable#{version}-#{Arch.sym}/CLOUDHV-#{Arch.sym}.fd"
    end

    def firmware_root
      "/opt/fw"
    end

    def path
      "#{firmware_root}/CLOUDHV-#{version}.fd"
    end

    def downloaded?
      File.exist?(path)
    end

    def download
      return if downloaded?
      FileUtils.mkdir_p(firmware_root)

      safe_write_to_file(path) do |f|
        unless curl_file(url, f.path) == sha256
          fail "Invalid SHA-256 digest"
        end
      end

      sha256
    end

    default = Arch.render(
      x64: new("202311", "e31738aacd3d68d30f8f9a4d09711cca3dfb414e8910dc3af90c50f36885380a"),
      arm64: new("202211", "482f428f782591d7c2222e0bc8240d25fb200fb21fd984b3339c85979d94b4d8")
    )
    SUPPORTED = {default.version => default}.freeze
    INSTALLED = SUPPORTED.select { _2.downloaded? }
    INSTALLED.default = default if default.downloaded?
    INSTALLED.freeze

    def self.[](version)
      INSTALLED[version]
    end

    def self.download
      SUPPORTED.each_value(&:download)
    end
  end

  class Version < Struct.new(:version, :sha256_ch_bin, :sha256_ch_remote)
    def url_for(type)
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/#{type}#{self.class.exe_suffix}"
    end

    def ch_remote_url
      url_for("ch-remote")
    end

    def cloud_hypervisor_url
      url_for("cloud-hypervisor")
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

    def downloaded?
      File.exist?(bin) && File.exist?(ch_remote_bin)
    end

    def download
      download_file(ch_remote_url, ch_remote_bin, sha256_ch_remote)
      download_file(cloud_hypervisor_url, bin, sha256_ch_bin)
    end

    def download_file(url, path, sha256)
      return if File.exist?(path)
      FileUtils.mkdir_p(dir)

      safe_write_to_file(path) do |f|
        unless curl_file(url, f.path) == sha256
          fail "Invalid SHA-256 digest"
        end
      end

      FileUtils.chmod "a+x", path
    end

    def self.ubuntu_version
      File.read("/etc/os-release")[/VERSION_ID="?(\d\d)/, 1]&.to_i or raise "unable to determine Ubuntu version"
    end

    SUPPORTED = {"35.1" => Arch.render(
      x64: new("35.1", "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4", "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0"),
      arm64: new("35.1", "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606", "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249")
    )}

    if ubuntu_version >= 24
      SUPPORTED["46.0"] = Arch.render(
        x64: new("46.0", "00b5cf2976847d2f21d2b7266038c8fc40bd14f2a542115055e9e214867edc9e", "526c91cf6b2d30b24af6eb39511f4f562f7bbc50a4dfb17d486274057a162445"),
        arm64: new("46.0", "a5a19c7e7326a5ca5dcf83a7b895a03e81cdac8c7d0690d4e94133cc89d38561", "6395a86db76f1f50d8b8c0ae1debbbb6a08e572b6f8c57cfbd9511e9beb4126a")
      )
    end

    default = SUPPORTED["35.1"]
    SUPPORTED.freeze

    INSTALLED = SUPPORTED.select { _2.downloaded? }
    INSTALLED.default = if default.downloaded?
      default
    else
      INSTALLED.values.first
    end
    INSTALLED.freeze

    EXE_SUFFIX = Arch.render(x64: "-static", arm64: "-static-aarch64")

    def self.[](version)
      INSTALLED[version]
    end

    def self.download
      SUPPORTED.each_value(&:download)
    end

    def self.exe_suffix
      EXE_SUFFIX
    end
  end
end
