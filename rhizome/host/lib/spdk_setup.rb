# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "spdk_path"
require "fileutils"

class SpdkSetup
  def initialize(spdk_version)
    @spdk_version = spdk_version
  end

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
    @install_path ||= SpdkPath.install_path(@spdk_version)
  end

  def spdk_service
    @spdk_service ||=
      (@spdk_version == LEGACY_SPDK_VERSION) ?
          "spdk.service" :
          "spdk-#{@spdk_version}.service"
  end

  def hugepages_mount_service
    @hugepages_mount_service ||= hugepages_dir.split("/")[1..].join("-") + ".mount"
  end

  def hugepages_dir
    @hugepages_dir ||= SpdkPath.hugepages_dir(@spdk_version)
  end

  def rpc_sock
    @rpc_sock ||= SpdkPath.rpc_sock(@spdk_version)
  end

  def package_url
    arch = if Arch.arm64?
      :arm64
    elsif Arch.x64?
      :x64
    else
      fail "BUG: unexpected architecture"
    end

    {
      ["v23.09", :arm64] => "https://github.com/ubicloud/spdk/releases/download/v23.09/spdk-arm64.tar.gz",
      ["v23.09", :x64] => "https://github.com/ubicloud/spdk/releases/download/v23.09/spdk-23.09-x64.tar.gz",
      ["v23.09-ubi-0.2", :arm64] => "https://github.com/ubicloud/bdev_ubi/releases/download/spdk-23.09-ubi-0.2-arm64/ubicloud-spdk-ubuntu-22.04-arm64.tar.gz",
      ["v23.09-ubi-0.2", :x64] => "https://github.com/ubicloud/bdev_ubi/releases/download/spdk-23.09-ubi-0.2/ubicloud-spdk-ubuntu-22.04-x64.tar.gz"
    }.fetch([@spdk_version, arch])
  end

  def has_bdev_ubi?
    @spdk_version.match?(/^v[0-9]+\.[0-9]+-ubi-.*/)
  end

  def vhost_target
    @vhost_target ||= has_bdev_ubi? ? "vhost_ubi" : "vhost"
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
    vhost_binary = SpdkPath.bin(@spdk_version, vhost_target)
    File.write("/lib/systemd/system/#{spdk_service}", <<SPDK_SERVICE
[Unit]
Description=Block Storage Service #{@spdk_version}
Requires=#{hugepages_mount_service}
[Service]
Type=simple
Environment="XDG_RUNTIME_DIR=#{SpdkPath.home.shellescape}"
ExecStart=#{vhost_binary} -S #{SpdkPath.vhost_dir.shellescape} \
--huge-dir #{hugepages_dir.shellescape} \
--iova-mode va \
--rpc-socket #{rpc_sock.shellescape} \
--cpumask [0,1] \
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
Description=SPDK hugepages mount #{@spdk_version}

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
