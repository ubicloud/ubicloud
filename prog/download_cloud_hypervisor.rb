# frozen_string_literal: true

class Prog::DownloadCloudHypervisor < Prog::Base
  subject_is :sshable, :vm_host

  def version
    @version ||= frame.fetch("version")
  end

  def sha256_ch_bin
    @sha256_ch_bin ||= frame.fetch("sha256_ch_bin") || sha_256("ch-bin")
  end

  def sha256_ch_remote
    @sha256_ch_remote ||= frame.fetch("sha256_ch_remote") || sha_256("ch-remote")
  end

  label def start
    fail "Version is required" if version.nil?
    fail "SHA-256 digest of cloud-hypervisor is required" if sha256_ch_bin.nil?
    fail "SHA-256 digest of ch-remote is required" if sha256_ch_remote.nil?

    hop_download
  end

  label def download
    daemon_name = "download_ch_#{version}"
    case sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      pop({"msg" => "cloud hypervisor downloaded", "version" => version,
        "sha256_ch_bin" => sha256_ch_bin, "sha256_ch_remote" => sha256_ch_remote})
    when "NotStarted"
      d_command = NetSsh.command("host/bin/download-cloud-hypervisor :version :sha256_ch_bin :sha256_ch_remote", version:, sha256_ch_bin:, sha256_ch_remote:)
      sshable.cmd("common/bin/daemonizer :d_command :daemon_name", daemon_name:, d_command:)
    when "Failed"
      fail "Failed to download cloud hypervisor version #{version} on #{vm_host}"
    end

    nap 15
  end

  HASHES = {
    ["ch-bin", "x64", "35.1"] => "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4",
    ["ch-remote", "x64", "35.1"] => "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0",
    ["ch-bin", "arm64", "35.1"] => "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606",
    ["ch-remote", "arm64", "35.1"] => "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249",
    ["ch-bin", "x64", "46.0"] => "00b5cf2976847d2f21d2b7266038c8fc40bd14f2a542115055e9e214867edc9e",
    ["ch-remote", "x64", "46.0"] => "526c91cf6b2d30b24af6eb39511f4f562f7bbc50a4dfb17d486274057a162445",
    ["ch-bin", "arm64", "46.0"] => "a5a19c7e7326a5ca5dcf83a7b895a03e81cdac8c7d0690d4e94133cc89d38561",
    ["ch-remote", "arm64", "46.0"] => "6395a86db76f1f50d8b8c0ae1debbbb6a08e572b6f8c57cfbd9511e9beb4126a"
  }

  def sha_256(bin)
    HASHES[[bin, vm_host.arch, version]]
  end
end
