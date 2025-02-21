# frozen_string_literal: true

DEFAULT_SPDK_VERSION = "v23.09-ubi-0.3"

module SpdkPath
  def self.user
    "spdk"
  end

  def self.home
    File.join("", "home", user)
  end

  def self.vhost_dir
    File.join("", "var", "storage", "vhost")
  end

  def self.vhost_sock(controller)
    File.join(vhost_dir, controller)
  end

  def self.vhost_controller(vm_name, disk_index)
    "#{vm_name}_#{disk_index}"
  end

  def self.hugepages_dir(spdk_version)
    # Hugepages path can't have any "-" characters. This is because mount
    # service name should match the path, and the "-" s in mount service name
    # are regarded as "/" s in the path.
    File.join(home, "hugepages.#{spdk_version.tr("-", ".")}")
  end

  def self.rpc_sock(spdk_version)
    File.join(home, "spdk-#{spdk_version}.sock")
  end

  def self.conf_path(spdk_version)
    File.join(home, "spdk-#{spdk_version}.conf")
  end

  def self.install_prefix
    File.join("", "opt")
  end

  def self.install_path(spdk_version)
    File.join(install_prefix, "spdk-#{spdk_version}")
  end

  def self.bin(version, n)
    File.join(install_path(version), "bin", n)
  end
end
