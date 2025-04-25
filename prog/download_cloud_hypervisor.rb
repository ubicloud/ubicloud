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

  HASHES = {
    ["ch-bin", "x64", "35.1"] => "e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4",
    ["ch-remote", "x64", "35.1"] => "337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0",
    ["ch-bin", "arm64", "35.1"] => "071a0b4918565ce81671ecd36d65b87351c85ea9ca0fbf73d4a67ec810efe606",
    ["ch-remote", "arm64", "35.1"] => "355cdb1e2af7653a15912c66f7c76c922ca788fd33d77f6f75846ff41278e249",
    ["ch-bin", "x64", "45.0"] => "362d42eb464e2980d7b41109a214f8b1518b4e1f8e7d8c227b67c19d4581c250",
    ["ch-remote", "x64", "45.0"] => "11a050087d279f9b5860ddbf2545fda43edf93f9b266440d0981932ee379c6ec",
    ["ch-bin", "arm64", "45.0"] => "3a8073379d098817d54f7c0ab25a7734b88b070a98e5d820ab39e244b35b5e5e",
    ["ch-remote", "arm64", "45.0"] => "a4b736ce82f5e2fc4a92796a9a443f243ef69f4970dad1e1772bd841c76c3301"
  }

  def sha_256(bin)
    HASHES[[bin, vm_host.arch, version]]
  end
end
