# frozen_string_literal: true

require_relative "../../common/lib/util"

# Replaces the packages that CustomKernel installed with the stock packages.
class CustomKernelRemoval
  CUSTOM_VERSION = /\A(.+)\+ubi\d+\z/

  def remove
    apt_get("update")
    packages = custom_packages
    r "apt-mark", "unhold", *packages.keys unless packages.empty?
    apt_get("install", "--allow-downgrades", "linux-image-generic", *packages.flat_map { |name, version| stock_changes(name, version) })
    apt_get("full-upgrade")

    remaining = custom_packages
    fail "Custom kernel packages are still installed: #{remaining.keys.join(", ")}" unless remaining.empty?
  end

  # dpkg-query exits 1 when no package matches a pattern.
  def custom_packages
    r("dpkg-query", "-W", "-f", "${db:Status-Status} ${Package} ${Version}\n", "linux-image-unsigned-*", "linux-modules-*", expect: [0, 1])
      .lines.map(&:split)
      .select { |status, _, version| status == "installed" && CUSTOM_VERSION.match?(version) }
      .to_h { |_, name, version| [name, version] }
  end

  # The signed stock image does not replace the unsigned image by name, so
  # the unsigned image is removed explicitly.
  def stock_changes(name, version)
    stock_version = version[CUSTOM_VERSION, 1]
    stock_name = name.sub(/\Alinux-image-unsigned-/, "linux-image-")
    return ["#{name}-"] unless available?(stock_name, stock_version)

    changes = ["#{stock_name}=#{stock_version}"]
    changes << "#{name}-" unless stock_name == name
    changes
  end

  # apt-cache prints nothing for an unknown version of a known package, and
  # exits 100 for an unknown package.
  def available?(name, version)
    !r("apt-cache", "show", "#{name}=#{version}", expect: [0, 100]).empty?
  end

  def apt_get(*args)
    r "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "-y", *args
  end
end
