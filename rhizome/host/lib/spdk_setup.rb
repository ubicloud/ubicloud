# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require_relative "spdk_path"
require "fileutils"
require "json"

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

  def conf_path
    @conf_path ||= SpdkPath.conf_path(@spdk_version)
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

  def create_service(cpu_count:)
    user = SpdkPath.user
    vhost_binary = SpdkPath.bin(@spdk_version, vhost_target)
    cpumask = (0..cpu_count - 1).to_a.join(",")
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
--cpumask [#{cpumask}] \
--disable-cpumask-locks \
--config #{conf_path.shellescape}
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
Options=uid=#{user},size=2G

[Install]
WantedBy=#{spdk_service}
SPDK_HUGEPAGES_MOUNT
    )
  end

  def create_conf
    iobuf_conf = [{
      method: "iobuf_set_options",
      params: {
        # Each bdev iobuf channel requires 128 small pool items & 16 large pool
        # items. These are hard-coded in v23.09 and aren't configurable. Each
        # accel iobuf channel requires 128 small pool & 16 large pool items.
        # These values are configurable using accel_set_options.
        #
        # An unencrypted volume requires 1 bdev & 1 accel iobuff channels. An
        # encrypted volume requires 1 bdev & 2 accel iobuff channels.
        #
        # So, small_pool_count must be at least #Volumes-per-host*3*128, and
        # large_pool_count must be at least #Volumes-per-host*3*16. This config,
        # which modifies the defaults, is enough for 100 encrypted volumes in a
        # host.
        small_pool_count: 38400,
        large_pool_count: 4800,
        small_bufsize: 8192,
        large_bufsize: 135168
      }
    }]

    # Leave these same as defaults for now.
    accel_conf = [{
      method: "accel_set_options",
      params: {
        small_cache_size: 128,
        large_cache_size: 16,
        task_count: 2048,
        sequence_count: 2048,
        buf_count: 2048
      }
    }]

    bdev_conf = [{
      method: "bdev_set_options",
      params: {
        # SPDK pre-populates the bdev_io cache per each io_channel. So,
        # bdev_io_pool_size should be least #io_channels * bdev_io_cache_size.
        # Therefore, bdev_io_pool_size must be #Volumes-per-host * 256.
        #
        # The default config is enough for 512 volumes in a host, so keeping it
        # as it is.
        bdev_io_pool_size: 65536,
        bdev_io_cache_size: 256,
        bdev_auto_examine: true
      }
    }]

    safe_write_to_file(conf_path, JSON.pretty_generate({
      subsystems: [
        {
          subsystem: "iobuf",
          config: iobuf_conf
        },
        {
          subsystem: "accel",
          config: accel_conf
        },
        {
          subsystem: "bdev",
          config: bdev_conf
        }
      ]
    }))
  end

  def enable_services
    r "systemctl enable #{hugepages_mount_service}"
    r "systemctl enable #{spdk_service}"
  end

  def start_services
    r "systemctl start #{hugepages_mount_service}"
    r "systemctl start #{spdk_service}"
  end

  def stop_and_remove_services
    r "systemctl stop #{spdk_service}"
    r "systemctl stop #{hugepages_mount_service}"
    r "systemctl disable #{spdk_service}"
    r "systemctl disable #{hugepages_mount_service}"
    FileUtils.rm_f("/lib/systemd/system/#{spdk_service}")
    FileUtils.rm_f("/lib/systemd/system/#{hugepages_mount_service}")
  end

  def remove_paths
    FileUtils.rm_f(conf_path)
    FileUtils.rm_rf(hugepages_dir)
    FileUtils.rm_rf(install_path)
  end

  def verify_spdk
    status = (r "systemctl is-active #{spdk_service}").strip
    fail "SPDK failed to start" unless status == "active"
  end
end
