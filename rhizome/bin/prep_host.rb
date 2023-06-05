#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"
require_relative "../lib/cloud_hypervisor"
require "fileutils"

# YYY: we should check against digests of each artifact, to detect and
# report any unexpected content changes (e.g., supply chain attack).

ch_dir = "/opt/cloud-hypervisor/v#{CloudHypervisor::VERSION}"
FileUtils.mkdir_p(ch_dir)
FileUtils.cd ch_dir do
  r "curl -L3 -O https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{CloudHypervisor::VERSION}/ch-remote"
  FileUtils.chmod "a+x", "ch-remote"
  r "curl -L3 -O https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v#{CloudHypervisor::VERSION}/cloud-hypervisor"
  FileUtils.chmod "a+x", "cloud-hypervisor"
end

# edk2 firmware
fw_dir = File.dirname(CloudHypervisor.firmware)
FileUtils.mkdir_p(fw_dir)
FileUtils.cd fw_dir do
  r "curl -L3 -o #{CloudHypervisor.firmware.shellescape} https://github.com/fdr/edk2/releases/download/#{CloudHypervisor::FIRMWARE_VERSION}/CLOUDHV.fd"
end

# spdk
spdk_dir = "/opt"
FileUtils.cd spdk_dir do
  r "curl -L3 -o /tmp/spdk.tar.gz https://ubicloud-spdk2.s3.us-east-2.amazonaws.com/spdk.tar.gz"
  r "tar -xzf /tmp/spdk.tar.gz"
end

# spdk dependencies
r "apt-get -y install libaio-dev libssl-dev libnuma-dev libjson-c-dev uuid-dev libiscsi-dev"

# Host-level network packet forwarding, otherwise packets cannot leave
# the physical interface.
File.write("/etc/sysctl.d/72-clover-forward-packets.conf", <<CONF)
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
CONF
r "sysctl --system"

# OS images.

# For qemu-image convert and mcopy for cloud-init with the nocloud
# driver.
r "apt-get -y install qemu-utils mtools"

# We currently use 512MB of hugepages per VM, so by requesting 8K 2MB pages as
# below, we will have enough hugepages for 32 VMs in a host.
#
# TODO: It is possible that OS allocates less hugepages than requested, so
# check how much hugepages were actually allocated, and use it in capacity
# calculations.
r "echo 8192 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
