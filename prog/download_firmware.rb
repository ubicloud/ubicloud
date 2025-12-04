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
    daemon_name = "download_firmware_#{version}"
    case sshable.cmd("common/bin/daemonizer --check :daemon_name", daemon_name:)
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean :daemon_name", daemon_name:)
      pop({"msg" => "firmware downloaded", "version" => version, "sha256" => sha256})
    when "NotStarted"
      d_command = NetSsh.command("host/bin/download-firmware :version :sha256", version:, sha256:)
      sshable.cmd("common/bin/daemonizer :d_command :daemon_name", daemon_name:, d_command:)
    when "Failed"
      fail "Failed to download firmware version #{version} on #{vm_host}"
    end

    nap 15
  end
end
