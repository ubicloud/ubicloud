# frozen_string_literal: true

module ContentGenerator
  module Vm
    def self.location(location)
      Option.locations(only_visible: false).find { _1[:display_name] == location }[:ui_name]
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
      unit_price = BillingRate.from_resource_properties("VmVCpu", "standard", location)["unit_price"].to_f

      [
        size.display_name,
        "#{size.vcpus} vCPUs / #{size.memory_gib} GB RAM",
        "$#{"%.2f" % (size.vcpus * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (size.vcpus * unit_price * 60)}/hour"
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

  module Postgres
    def self.location(flavor, location)
      Option.postgres_locations.find { _1[:display_name] == location }[:ui_name]
    end

    def self.size(flavor, location, size)
      location = LocationNameConverter.to_internal_name(location)
      size = Option::PostgresSizes.find { _1.display_name == size }
      unit_price = BillingRate.from_resource_properties("PostgresVCpu", flavor, location)["unit_price"].to_f

      [
        size.display_name,
        "#{size.vcpu} vCPUs / #{size.memory} GB RAM",
        "$#{"%.2f" % (size.vcpu * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (size.vcpu * unit_price * 60)}/hour"
      ]
    end

    def self.storage_size(flavor, location, vm_size, storage_size)
      location = LocationNameConverter.to_internal_name(location)
      unit_price = BillingRate.from_resource_properties("PostgresStorage", flavor, location)["unit_price"].to_f

      [
        "#{storage_size}GB",
        nil,
        "$#{"%.2f" % (storage_size.to_i * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (storage_size.to_i * unit_price * 60)}/hour"
      ]
    end

    def self.version(flavor, version)
      "Postgres #{version}"
    end

    def self.ha_type(flavor, location, vm_size, storage_size, ha_type)
      location = LocationNameConverter.to_internal_name(location)
      vcpu = Option::PostgresSizes.find { _1.display_name == vm_size }.vcpu
      ha_type = Option::PostgresHaOptions.find { _1.name == ha_type }
      compute_unit_price = BillingRate.from_resource_properties("PostgresVCpu", flavor, location)["unit_price"].to_f
      storage_unit_price = BillingRate.from_resource_properties("PostgresStorage", flavor, location)["unit_price"].to_f
      standby_count = ha_type.standby_count

      [
        ha_type.title,
        ha_type.explanation,
        "$#{"%.2f" % (standby_count * ((vcpu * compute_unit_price) + (storage_size.to_i * storage_unit_price)) * 60 * 672)}/mo",
        "$#{"%.3f" % (standby_count * ((vcpu * compute_unit_price) + (storage_size.to_i * storage_unit_price)) * 60)}/hour"
      ]
    end

    def self.partnership_notice(flavor)
      notice = {
        PostgresResource::Flavor::PARADEDB => [[
          "ParadeDB is an Elasticsearch alternative built on Postgres. ParadeDB instances are managed by the ParadeDB team and are optimal for search and analytics workloads.",
          "You can get ParadeDB specific support via email at <a href='mailto:support@paradedb.com' class='text-orange-600 font-semibold'>support@paradedb.com</a> or via Slack at <a href='https://join.slack.com/t/paradedbcommunity/shared_invite/zt-2lkzdsetw-OiIgbyFeiibd1DG~6wFgTQ' target='_blank' class='text-orange-600 font-semibold'>ParadeDB Community Slack</a>",
          "By creating a ParadeDB PostgreSQL database on Ubicloud you consent to your contact information being shared with ParadeDB team."
        ],
          "Accept <a href='https://paradedb.notion.site/Terms-of-Use-d17c9916a5b746fab86c274feb35da75' target='_blank' class='text-orange-600 font-semibold'>Terms of Service</a> and <a href='https://paradedb.notion.site/Privacy-Policy-a7ce333c45c8478fb03250dff7e573b7?pvs=4' target='_blank' class='text-orange-600 font-semibold'> Privacy Policy</a>"],
        PostgresResource::Flavor::LANTERN => [[
          "Lantern is a PostgreSQL-based vector database designed specifically for building AI applications. Lantern instances are managed by the Lantern team and are optimal for AI workloads.",
          "You can reach to Lantern team for support at <a href='mailto:support@lantern.dev' class='text-orange-600 font-semibold'>support@lantern.dev</a>",
          "By creating a Lantern PostgreSQL database on Ubicloud you consent to your contact information being shared with Lantern team."
        ],
          "Accept <a href='https://lantern.dev/legal/terms' target='_blank' class='text-orange-600 font-semibold'>Terms of Service</a> and <a href='https://lantern.dev/legal/privacy' target='_blank' class='text-orange-600 font-semibold'> Privacy Policy</a>"]
      }

      notice[flavor]
    end
  end

  module LoadBalancer
    def self.select_option(select_option)
      select_option[:display_name]
    end
  end

  module KubernetesCluster
    def self.location(location)
      Option.kubernetes_locations.find { _1.display_name == location }.ui_name
    end

    def self.cp_nodes(cp_nodes)
      cp_nodes.to_s
    end

    def self.worker_nodes(worker_nodes)
      worker_nodes[:display_name]
    end
  end
end
