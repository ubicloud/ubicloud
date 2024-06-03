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
    q_daemon_name = "download_ch_#{version}".shellescape
    case sshable.cmd("common/bin/daemonizer --check #{q_daemon_name}")
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean #{q_daemon_name}")
      pop({"msg" => "cloud hypervisor downloaded", "version" => version,
        "sha256_ch_bin" => sha256_ch_bin, "sha256_ch_remote" => sha256_ch_remote})
    when "NotStarted"
      sshable.cmd("common/bin/daemonizer 'host/bin/download-cloud-hypervisor #{version} #{sha256_ch_bin} #{sha256_ch_remote}' #{q_daemon_name}")
    when "Failed"
      fail "Failed to download cloud hypervisor version #{version} on #{vm_host}"
    end

    nap 15
  end

  def sha_256(bin)
    hashes = {
      ["ch-bin", "x64", "35.1"] => "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4",
      ["ch-remote", "x64", "35.1"] => "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0",
      ["ch-bin", "arm64", "35.1"] => "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606",
      ["ch-remote", "arm64", "35.1"] => "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249"
    }

    hashes[[bin, vm_host.arch, version]]
  end
end
