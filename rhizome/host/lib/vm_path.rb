# frozen_string_literal: true

require "shellwords"
require "yaml"

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

  def self.define_new_method(m, &block)
    fail "BUG" if method_defined?(m)
    define_method(m, &block)
  end

  # Define path, read, write methods for files in
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
    cert
  ].each do |file_name|
    method_name = file_name.tr(".-", "_")

    # Method producing a path, e.g. #user_data
    define_new_method method_name do
      home(file_name)
    end

    # Method reading the file's contents, e.g. #read_user_data
    #
    # Trailing newlines are removed.
    define_new_method("read_" + method_name) do
      read(home(file_name))
    end

    # Method overwriting the file's contents, e.g. #write_user_data
    write_method_name = "write_" + method_name
    define_new_method(write_method_name) do |s|
      write(home(file_name), s)
    end

    # Method serializing data to YAML and writing, e.g. #write_yaml_user_data
    define_method("write_yaml_" + method_name) do |data, prefix: nil|
      s = YAML.dump(data, line_width: -1)
      s.sub!(/\A---/, prefix) if prefix
      send(write_method_name, s)
    end
  end
end
