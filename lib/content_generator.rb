# frozen_string_literal: true

module ContentGenerator
  module Vm
    def self.location(location)
      Option.locations.find { _1.display_name == location }.ui_name
    end

    def self.private_subnet(location, private_subnet)
      private_subnet[:display_name]
    end

    def self.enable_ipv4(location, value)
      location = LocationNameConverter.to_internal_name(location)
      unit_price = BillingRate.from_resource_properties("IPAddress", "IPv4", location)["unit_price"].to_f

      "Enable Public IPv4 ($#{"%.2f" % (unit_price * 60 * 672)}/mo)"
    end

    def self.size(location, size)
      location = LocationNameConverter.to_internal_name(location)
      size = Option::VmSizes.find { _1.display_name == size }
      unit_price = BillingRate.from_resource_properties("VmCores", "standard", location)["unit_price"].to_f

      [
        size.display_name,
        "#{size.vcpu} vCPUs / #{size.memory} GB RAM",
        "$#{"%.2f" % ((size.vcpu / 2) * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % ((size.vcpu / 2) * unit_price * 60)}/hour"
      ]
    end

    def self.storage_size(location, vm_size, storage_size)
      storage_size = storage_size.to_i
      location = LocationNameConverter.to_internal_name(location)
      unit_price = BillingRate.from_resource_properties("VmStorage", "standard", location)["unit_price"].to_f

      [
        "#{storage_size}GB",
        nil,
        "$#{"%.2f" % (storage_size * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (storage_size * unit_price * 60)}/hour"
      ]
    end

    def self.boot_image(boot_image)
      Option::BootImages.find { _1.name == boot_image }.display_name
    end
  end
end
