#!/bin/env ruby
# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../lib/cloud_hypervisor"
require_relative "../lib/spdk_setup"
require "fileutils"
require "socket"

unless (hostname = ARGV.shift)
  puts "need host name as argument"
  exit 1
end

unless (env_type = ARGV.shift)
  puts "need environment type as argument"
  exit 1
end

original_hostname = Socket.gethostname

safe_write_to_file("/etc/hosts", File.read("/etc/hosts").gsub(original_hostname, hostname))
r "sudo hostnamectl set-hostname " + hostname

if env_type == "production"
  bashrc_content = File.read("/root/.bashrc")
  colored_prompt_code = '\e[0;41m[\u@\h \W]\$ \e[m'
  safe_write_to_file("/root/.bashrc", "#{bashrc_content}\n PS1='#{colored_prompt_code}'")
end

ch_dir = CloudHypervisor::VERSION.dir
FileUtils.mkdir_p(ch_dir)
FileUtils.cd ch_dir do
  r "curl -L3 -o ch-remote #{CloudHypervisor::VERSION.ch_remote_url.shellescape}"
  FileUtils.chmod "a+x", "ch-remote"
  r "curl -L3 -o cloud-hypervisor #{CloudHypervisor::VERSION.url.shellescape}"
  FileUtils.chmod "a+x", "cloud-hypervisor"
end

# edk2 firmware
fw_dir = File.dirname(CloudHypervisor::FIRMWARE.path)
FileUtils.mkdir_p(fw_dir)
FileUtils.cd fw_dir do
  r "curl -L3 -o #{CloudHypervisor::FIRMWARE.name.shellescape} #{CloudHypervisor::FIRMWARE.url.shellescape}"
end

# Err towards listing ('l') and not restarting services by default,
# otherwise a stray keystroke when using "apt install" for unrelated
# packages can restart systemd services that interrupt customers.
File.write("/etc/needrestart/conf.d/82-clover-default-list.conf", <<CONF)
$nrconf{restart} = 'l';
CONF

# Host-level network packet forwarding, otherwise packets cannot leave
# the physical interface.
File.write("/etc/sysctl.d/72-clover-forward-packets.conf", <<CONF)
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv4.conf.all.forwarding=1
net.ipv4.ip_forward=1
CONF
r "sysctl --system"

# OS images.

# For qemu-image convert and mcopy for cloud-init with the nocloud
# driver.
r "apt-get -y install qemu-utils mtools"

SpdkSetup.prep
