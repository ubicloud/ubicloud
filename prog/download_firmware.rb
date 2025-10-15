# frozen_string_literal: true

class Prog::DownloadFirmware < Prog::Base
  subject_is :sshable, :vm_host

  def version
    @version ||= frame.fetch("version")
  end

  def sha256
    @sha256 ||= frame.fetch("sha256")
  end

  label def start
    fail "Version is required" if version.nil?
    fail "SHA-256 digest is required" if sha256.nil?

    hop_download
  end

  label def download
    q_daemon_name = "download_firmware_#{version}".shellescape
    case sshable.cmd("common/bin/daemonizer --check #{q_daemon_name}")
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean #{q_daemon_name}")
      pop({"msg" => "firmware downloaded", "version" => version, "sha256" => sha256})
    when "NotStarted"
      sshable.cmd("common/bin/daemonizer 'host/bin/download-firmware #{version} #{sha256}' #{q_daemon_name}")
    when "Failed"
      fail "Failed to download firmware version #{version} on #{vm_host}"
    end

    nap 15
  end
end
