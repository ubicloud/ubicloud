# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "spdk_path"
require "fileutils"

class SpdkSetup
  def self.prep
    r "apt-get -y install libaio-dev libssl-dev libnuma-dev libjson-c-dev uuid-dev libiscsi-dev"

    begin
      r "adduser #{SpdkPath.user.shellescape} --disabled-password --gecos '' --home #{SpdkPath.home.shellescape}"
    rescue CommandFail => ex
      raise unless /adduser: The user `.*' already exists\./.match?(ex.message)
    end

    # Directory to put vhost sockets.
    FileUtils.mkdir_p(SpdkPath.vhost_dir)
    FileUtils.chown SpdkPath.user, SpdkPath.user, SpdkPath.vhost_dir
  end

  def install_path
    @install_path ||= SpdkPath.install_path
  end

  def spdk_service
    "spdk.service"
  end

  def hugepages_mount_service
    "home-spdk-hugepages.mount"
  end

  def hugepages_dir
    @hugepages_dir ||= SpdkPath.hugepages_dir
  end

  def rpc_sock
    @rpc_sock ||= SpdkPath.rpc_sock
  end

  def vhost_binary
    @vhost_binary ||= SpdkPath.bin("vhost")
  end

  def package_url
    if Arch.arm64?
      "https://github.com/ubicloud/spdk/releases/download/v23.09/spdk-arm64.tar.gz"
    elsif Arch.x64?
      "https://github.com/ubicloud/spdk/releases/download/v23.09/spdk-23.09-x64.tar.gz"
    else
      fail "BUG: unexpected architecture"
    end
  end

  def install_package
    temp_tarball = "/tmp/spdk.tar.gz"
    r "curl -L3 -o #{temp_tarball} #{package_url}"

    FileUtils.mkdir_p(install_path)
    FileUtils.cd install_path do
      r "tar -xzf #{temp_tarball} --strip-components=1"
    end
  end

  def create_service
    user = SpdkPath.user
    File.write("/lib/systemd/system/#{spdk_service}", <<SPDK_SERVICE
[Unit]
Description=Block Storage Service
Requires=#{hugepages_mount_service}
[Service]
Type=simple
Environment="XDG_RUNTIME_DIR=#{SpdkPath.home.shellescape}"
ExecStart=#{vhost_binary} -S #{SpdkPath.vhost_dir.shellescape} \
--huge-dir #{hugepages_dir.shellescape} \
--iova-mode va \
--rpc-socket #{rpc_sock.shellescape} \
--cpumask [0] \
--disable-cpumask-locks
ExecReload=/bin/kill -HUP $MAINPID
LimitMEMLOCK=8400113664
PrivateDevices=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectHome=no
NoNewPrivileges=yes
User=#{user}
Group=#{user}
[Install]
WantedBy=multi-user.target
Alias=#{spdk_service}
SPDK_SERVICE
    )
  end

  def create_hugepages_mount
    user = SpdkPath.user
    r "sudo --user=#{user.shellescape} mkdir -p #{hugepages_dir.shellescape}"

    File.write("/lib/systemd/system/#{hugepages_mount_service}", <<SPDK_HUGEPAGES_MOUNT
[Unit]
Description=SPDK hugepages mount

[Mount]
What=hugetlbfs
Where=#{hugepages_dir}
Type=hugetlbfs
Options=uid=#{user},size=1G

[Install]
WantedBy=#{spdk_service}
SPDK_HUGEPAGES_MOUNT
    )
  end

  def enable_services
    r "systemctl enable #{hugepages_mount_service}"
    r "systemctl enable #{spdk_service}"
  end

  def start_services
    r "systemctl start #{hugepages_mount_service}"
    r "systemctl start #{spdk_service}"
  end

  def verify_spdk
    status = (r "systemctl is-active #{spdk_service}").strip
    fail "SPDK failed to start" unless status == "active"
  end
end
