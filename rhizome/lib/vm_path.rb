# frozen_string_literal: true

require "shellwords"

class VmPath
  def initialize(vm_name)
    @vm_name = vm_name
  end

  # Read from a path, removing a trailing newline if present.
  def read(path)
    File.read(path).chomp
  end

  # Write to a path, adding a trailing newline if not already present.
  def write(path, s)
    s += "\n" unless s.end_with?("\n")
    File.write(path, s)
  end

  def dnsmasq_service
    "/etc/systemd/system/#{@vm_name}-dnsmasq.service"
  end

  def write_dnsmasq_service(s)
    write(dnsmasq_service, s)
  end

  def radvd_service
    "/etc/systemd/system/#{@vm_name}-radvd.service"
  end

  def radvd_pid
    home("radvd.pid")
  end

  def write_radvd_service(s)
    write(radvd_service, s)
  end

  def systemd_service
    File.join("/etc/systemd/system",
      IO.popen(["systemd-escape", @vm_name + ".service"]) { _1.read.chomp })
  end

  def write_systemd_service(s)
    write(systemd_service, s)
  end

  def home(n)
    File.join("", "vm", @vm_name, n)
  end

  def storage_root
    File.join("", "var", "storage", @vm_name)
  end

  def storage(disk_index, n)
    File.join(storage_root, disk_index.to_s, n)
  end

  # Define path, q_path, read, write methods for files in
  # `/vm/#{vm_name}`
  %w[
    guest_ephemeral
    clover_ephemeral
    dnsmasq.conf
    meta-data
    network-config
    user-data
    cloudinit.img
    ch-api.sock
    serial.log
    hugepages
    public_ipv4
    nftables_conf
    prep.json
    radvd.conf
  ].each do |file_name|
    method_name = file_name.tr(".-", "_")
    fail "BUG" if method_defined?(method_name)

    # Method producing a path, e.g. #user_data
    define_method method_name do
      home(file_name)
    end

    # Method producing a shell-quoted path, e.g. #q_user_data.
    quoted_method_name = "q_" + method_name
    fail "BUG" if method_defined?(quoted_method_name)
    define_method quoted_method_name do
      home(file_name).shellescape
    end

    # Method reading the file's contents, e.g. #read_user_data
    #
    # Trailing newlines are removed.
    read_method_name = "read_" + method_name
    fail "BUG" if method_defined?(read_method_name)
    define_method read_method_name do
      read(home(file_name))
    end

    # Method overwriting the file's contents, e.g. #write_user_data
    write_method_name = "write_" + method_name
    fail "BUG" if method_defined?(write_method_name)
    define_method write_method_name do |s|
      write(home(file_name), s)
    end
  end

  def vhost_sock(disk_index)
    storage(disk_index, "vhost.sock")
  end

  def disk(disk_index)
    storage(disk_index, "disk.raw")
  end

  def data_encryption_key(disk_index)
    storage(disk_index, "data_encryption_key.json")
  end
end
