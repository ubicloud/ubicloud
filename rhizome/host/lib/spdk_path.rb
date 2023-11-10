# frozen_string_literal: true

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

  def self.hugepages_dir
    File.join(home, "hugepages")
  end

  def self.rpc_sock
    File.join(home, "spdk.sock")
  end

  def self.install_prefix
    File.join("", "opt")
  end

  def self.install_path
    File.join(install_prefix, "spdk")
  end

  def self.bin(n)
    File.join(install_path, "bin", n)
  end
end
