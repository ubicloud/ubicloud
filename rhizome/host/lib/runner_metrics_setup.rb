# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "vm_path"
require "fileutils"
require "json"

class RunnerMetricsSetup
  ADDRESS = "fd00:0b1c:100d:57a7::"
  VERSION = "0.1.0"
  SHA256_BY_ARCH = {
    x64: "380d4a0a44f10757d57d32443c6f825bfd309fd0937a95d72fe14a7c7791d7f3",
    arm64: "4bf639de91d5ef8fa81c24b54cb9340eb6a384652a8ed4e75069e7e9c3b51691",
  }.freeze
  INSTALL_DIR = "/opt/runner-metrics/#{VERSION}"
  BIN = "#{INSTALL_DIR}/runner-metrics"

  def initialize(vm_name)
    @vm_name = vm_name
  end

  def metrics_dir
    VmPath.new(@vm_name).home("metrics")
  end

  def service_name
    "#{@vm_name}-metrics"
  end

  def service_file_path
    "/etc/systemd/system/#{service_name}.service"
  end

  def package_url
    arch = Arch.render(x64: "amd64", arm64: "arm64")
    "https://github.com/ubicloud/runner-metrics/releases/download/#{VERSION}/runner-metrics-linux-#{arch}-#{VERSION}.tar.gz"
  end

  # The binary is shared by every VM on the host, so it is fetched once
  # and only published after its digest checks out.
  def download_binary
    return if File.exist?(BIN)

    FileUtils.mkdir_p(INSTALL_DIR)
    tarball = File.join(INSTALL_DIR, "runner-metrics.tar.gz")
    safe_write_to_file(tarball) do |f|
      unless curl_file(package_url, f.path) == SHA256_BY_ARCH.fetch(Arch.sym)
        fail "Invalid SHA-256 digest"
      end
    end
    safe_write_to_file(BIN) do |f|
      r "tar -xzOf :tarball runner-metrics > :path", tarball: tarball, path: f.path
      FileUtils.chmod(0o755, f.path)
    end
    FileUtils.rm_f(tarball)
  end

  def setup(labels)
    download_binary

    FileUtils.mkdir_p(["#{metrics_dir}/pending", "#{metrics_dir}/done"])
    safe_write_to_file("#{metrics_dir}/labels.json", JSON.generate(labels))
    r "chown", "-R", "#{@vm_name}:#{@vm_name}", metrics_dir

    safe_write_to_file(service_file_path, <<~SERVICE)
      [Unit]
      Description=Runner metrics listener for #{@vm_name}
      After=network.target

      [Service]
      NetworkNamespacePath=/var/run/netns/#{@vm_name}
      ExecStart=#{BIN} #{metrics_dir}
      Restart=always
      RestartSec=2
      User=#{@vm_name}
      Group=#{@vm_name}
      ProtectSystem=strict
      ReadWritePaths=#{metrics_dir}
      PrivateTmp=yes
      NoNewPrivileges=yes
      MemoryMax=32M
      CPUQuota=20%

      [Install]
      WantedBy=multi-user.target
    SERVICE

    r "systemctl", "daemon-reload"
    r "systemctl", "enable", "--now", service_name
  end

  def stop_and_remove
    if File.exist?(service_file_path)
      r "systemctl", "disable", "--now", service_name
      rm_if_exists(service_file_path)
      r "systemctl", "daemon-reload"
    end
    rm_if_exists("#{service_file_path}.tmp.lock")
    rm_if_exists(metrics_dir)
  end
end
