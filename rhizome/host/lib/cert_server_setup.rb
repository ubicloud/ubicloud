# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "vm_path"
require "fileutils"
require "json"

class CertServerSetup
  def initialize(vm_name)
    @vm_name = vm_name
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def cert_folder
    vp.q_cert
  end

  def cert_path
    "#{cert_folder}/cert.pem"
  end

  def key_path
    "#{cert_folder}/key.pem"
  end

  def service_name
    "#{@vm_name}-metadata-endpoint"
  end

  def service_file_path
    "/etc/systemd/system/#{service_name}.service"
  end

  def server_version
    "0.1.5"
  end

  def server_main_path
    File.join("", "opt", "metadata-endpoint-#{server_version}")
  end

  def vm_server_path
    File.join(cert_folder, "metadata-endpoint-#{server_version}")
  end

  def package_url
    Arch.render(
      x64: "https://github.com/ubicloud/metadata-endpoint/releases/download/v#{server_version}/metadata-endpoint_Linux_x86_64.tar.gz",
      arm64: "https://github.com/ubicloud/metadata-endpoint/releases/download/v#{server_version}/metadata-endpoint_Linux_arm64.tar.gz"
    )
  end

  def copy_server
    unless File.exist?(server_main_path)
      download_server
    end

    r "cp #{server_main_path}/metadata-endpoint #{vm_server_path}"
    r "sudo chown #{@vm_name}:#{@vm_name} #{vm_server_path}"
  end

  def download_server
    temp_tarball = "/tmp/metadata-endpoint-#{server_version}.tar.gz"
    r "curl -L3 -o #{temp_tarball} #{package_url}"

    FileUtils.mkdir_p(server_main_path)
    FileUtils.cd server_main_path do
      r "tar -xzf #{temp_tarball}"
    end

    FileUtils.rm_f(temp_tarball)
  end

  def create_service
    service = "#{service_name}.service"
    File.write("/etc/systemd/system/#{service}", <<CERT_SERVICE
[Unit]
Description=Certificate Server
After=network.target

[Service]
NetworkNamespacePath=/var/run/netns/#{@vm_name}
ExecStart=#{vm_server_path}
Restart=always
Type=simple
ProtectSystem=strict
PrivateDevices=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
NoNewPrivileges=yes
ReadOnlyPaths=#{cert_path} #{key_path}
User=#{@vm_name}
Group=#{@vm_name}
Environment=VM_INHOST_NAME=#{@vm_name}
Environment=IPV6_ADDRESS="FD00:0B1C:100D:5AFE:CE::"
Environment=GOMEMLIMIT=9MiB
Environment=GOMAXPROCS=1
CPUQuota=50%
MemoryLimit=10M

CERT_SERVICE
    )
  end

  def enable_and_start_service
    r "systemctl enable #{service_file_path}"
    r "systemctl start #{service_name}"
  end

  def stop_and_remove_service
    r "systemctl stop #{service_name}"
    r "systemctl disable #{service_name}"
    FileUtils.rm_f(service_file_path)
  end

  def remove_paths
    FileUtils.rm_rf(cert_folder)
  end
end
