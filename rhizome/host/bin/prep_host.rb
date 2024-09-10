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

# Set up hostname to better identify servers in transcripts.
original_hostname = Socket.gethostname
is_prod_env = (env_type == "production")

safe_write_to_file("/etc/hosts", File.read("/etc/hosts").gsub(original_hostname, hostname))
r "sudo hostnamectl set-hostname " + hostname

# Color prompt and MOTD to cue operators as to production-level
# status.
color_code = is_prod_env ? "\e[31m" : "\e[32m"

reset_color_code = "\e[0m"

bashrc_content = File.read("/root/.bashrc")
colored_prompt_code = color_code + '[\u@\h \W]\$ ' + reset_color_code
safe_write_to_file("/root/.bashrc", "#{bashrc_content}\n PS1='#{colored_prompt_code}'")

motd_message = <<~'MOTD_MESSAGE'
       _     _      _                 _
 _   _| |__ (_) ___| | ___  _   _  __| |
| | | |  _ \| |/ __| |/ _ \| | | |/ _  |
| |_| | |_) | | (__| | (_) | |_| | (_| |
 \__,_|_.__/|_|\___|_|\___/ \__,_|\__,_|
MOTD_MESSAGE

safe_write_to_file("/etc/update-motd.d/99-clover-motd", <<~MOTD_SCRIPT)
#!/bin/bash
echo '#{color_code}#{motd_message}#{reset_color_code}'
MOTD_SCRIPT

r "chmod +x /etc/update-motd.d/99-clover-motd"

# Set up time zone.
r "timedatectl set-timezone UTC"

# Download cloud hypervisor binaries.
CloudHypervisor::VERSION.download

# Download firmware binaries.
CloudHypervisor::FIRMWARE.download

# Err towards listing ('l') and not restarting services by default,
# otherwise a stray keystroke when using "apt install" for unrelated
# packages can restart systemd services that interrupt customers.
FileUtils.mkdir_p("/etc/needrestart/conf.d")
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
# acl is for setfacl, which is used to set permissions and not installed
# by default in Leaseweb servers.
r "apt-get -y install qemu-utils mtools acl"

# We need nvme-cli to inspect installed NVMe cards in prod servers when
# looking into I/O performance issues. systemd-coredump is useful when
# debugging crashes.
r "apt-get -y install nvme-cli systemd-coredump" if is_prod_env

SpdkSetup.prep

# cron job to store serial.log files
FileUtils.mkdir_p("/var/log/ubicloud/serials")
File.write("/etc/cron.d/ubicloud-clean-serial-logs", <<CRON)
0 * * * * root /home/rhizome/host/bin/delete-old-serial-logs
CRON

r "systemctl enable cron"
r "systemctl start cron"

# Taken from https://infosec.mozilla.org/guidelines/openssh
safe_write_to_file("/etc/ssh/ssh_config.d/10-clover.conf", <<~SSHD_CONFIG)
# Supported HostKey algorithms by order of preference.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key

KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com

# Password based logins are disabled - only public key based logins are allowed.
AuthenticationMethods publickey

# LogLevel VERBOSE logs user's key fingerprint on login. Needed to have a clear audit track of which key was using to log in.
LogLevel VERBOSE
SSHD_CONFIG
