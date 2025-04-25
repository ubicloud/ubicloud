# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

module CloudHypervisor
  class Firmware < Struct.new(:version, :sha256)
    DEFAULT = Arch.render(
      x64: new("202311", "e31738aacd3d68d30f8f9a4d09711cca3dfb414e8910dc3af90c50f36885380a"),
      arm64: new("202211", "482f428f782591d7c2222e0bc8240d25fb200fb21fd984b3339c85979d94b4d8")
    )

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

      safe_write_to_file(path) do |f|
        unless curl_file(url, f.path) == sha256
          fail "Invalid SHA-256 digest"
        end
      end

      sha256
    end
  end

  class Version < Struct.new(:version, :sha256_ch_bin, :sha256_ch_remote)
    EXE_SUFFIX = Arch.render(x64: "-static", arm64: "-static-aarch64")

    v45 = Arch.render(
      x64: new("45.0", "362d42eb464e2980d7b41109a214f8b1518b4e1f8e7d8c227b67c19d4581c250", "11a050087d279f9b5860ddbf2545fda43edf93f9b266440d0981932ee379c6ec"),
      arm64: new("45.0", "3a8073379d098817d54f7c0ab25a7734b88b070a98e5d820ab39e244b35b5e5e", "a4b736ce82f5e2fc4a92796a9a443f243ef69f4970dad1e1772bd841c76c3301")
    )
    v35 = Arch.render(
      x64: new("35.1", "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4", "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0"),
      arm64: new("35.1", "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606", "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249")
    )

    if `lsb_release -d`.include?("Ubuntu 24.")
      DEFAULT = v45
      OLD = v35
    else
      DEFAULT = v35
    end

    def url_for(type)
      "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{version}/#{type}#{EXE_SUFFIX}"
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
  end
end
