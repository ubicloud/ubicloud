# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"
require "tmpdir"

# Installs and holds a kernel from https://github.com/ubicloud/ubuntu-kernel-build.
# The unsigned image removes linux-image-generic, so full-upgrade does not
# install a newer stock kernel.
class CustomKernel
  def initialize(version, url, sha256)
    unless (abi = version[/\A(\d+\.\d+\.\d+-\d+)\.\d+\+ubi\d+\z/, 1])
      fail "Invalid custom kernel version #{version.inspect}"
    end

    @version = version
    @url = url
    @sha256 = sha256
    @release = "#{abi}-generic"
  end

  SECURE_BOOT_VAR = "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa39-00e098032b8c"

  def packages
    ["linux-image-unsigned", "linux-modules", "linux-modules-extra"].map { |name| "#{name}-#{@release}" }
  end

  def apply_patches
    check_secure_boot
    apt_get("update")
    install unless installed?
    r "apt-mark", "hold", *packages
    apt_get("full-upgrade")
    check_default_kernel
  end

  # dpkg-query exits 1 when it does not know a package.
  def installed?
    status = r("dpkg-query", "-W", "-f", "${db:Status-Status} ${Version}\n", *packages, expect: [0, 1])
    status.lines.map(&:chomp) == packages.map { "installed #{@version}" }
  end

  def install
    Dir.mktmpdir("custom-kernel") do |dir|
      tarball = File.join(dir, "kernel.tar.gz")
      fail "Invalid SHA-256 digest" unless curl_file(@url, tarball) == @sha256

      r "tar", "-xzf", tarball, "-C", dir, "--no-same-owner", "--strip-components=1"
      arch = Arch.render(x64: "amd64", arm64: "arm64")
      apt_get("install", "--allow-change-held-packages", *packages.map { |package| File.join(dir, "#{package}_#{@version}_#{arch}.deb") })
    end
  end

  # Secure Boot does not boot the unsigned image. The first 4 bytes of the
  # variable are its attributes, and byte 4 is 1 when Secure Boot is on.
  def check_secure_boot
    return unless File.exist?(SECURE_BOOT_VAR) && File.binread(SECURE_BOOT_VAR).getbyte(4) == 1

    fail "Secure Boot is enabled, the unsigned custom kernel cannot boot"
  end

  # GRUB boots the newest installed kernel.
  def check_default_kernel
    newest = r("linux-version", "sort", stdin: r("linux-version", "list")).split.last
    return if newest == @release

    fail "Kernel #{newest} is newer than the custom kernel #{@release}, build the fix for #{newest}"
  end

  def apt_get(*args)
    r "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-y", *args
  end
end
