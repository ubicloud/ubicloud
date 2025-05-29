# frozen_string_literal: true

module ContentGenerator
  module Vm
    def self.location(location)
      location.ui_name
    end

    def self.private_subnet(location, private_subnet)
      private_subnet[:display_name]
    end

    def self.enable_ipv4(location, value)
      unit_price = BillingRate.unit_price_from_resource_properties("IPAddress", "IPv4", location.name)

      "Enable Public IPv4 ($#{"%.2f" % (unit_price * 60 * 672)}/mo)"
    end

    def self.family(location, family)
      vm_family = Option::VmFamilies.find { it.name == family }
      [
        vm_family.display_name,
        vm_family.ui_descriptor
      ]
    end

    def self.size(location, family, size)
      size = Option::VmSizes.find { it.display_name == size }
      unit_price = BillingRate.unit_price_from_resource_properties("VmVCpu", family, location.name)

      [
        size.display_name,
        "#{size.vcpus} vCPUs / #{size.memory_gib} GB RAM",
        "$#{"%.2f" % (size.vcpus * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (size.vcpus * unit_price * 60)}/hour"
      ]
    end

    def self.storage_size(location, family, vm_size, storage_size)
      storage_size = storage_size.to_i
      unit_price = BillingRate.unit_price_from_resource_properties("VmStorage", family, location.name)

      [
        "#{storage_size}GB",
        nil,
        "$#{"%.2f" % (storage_size * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (storage_size * unit_price * 60)}/hour"
      ]
    end

    def self.gpu(location, family, gpu)
      gpu = gpu.split(":")
      gpu_count = gpu[0].to_i

      unit_price = (gpu_count == 0) ? 0 : BillingRate.unit_price_from_resource_properties("Gpu", gpu[1], location.name)

      [
        (gpu_count == 0) ? "No GPU" : "#{gpu_count}x #{PciDevice.device_name(gpu[1])}",
        nil,
        "$#{"%.2f" % (gpu_count * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (gpu_count * unit_price * 60)}/hour"
      ]
    end

    def self.boot_image(boot_image)
      Option::BootImages.find { it.name == boot_image }.display_name
    end
  end

  module Postgres
    def self.location(flavor, location)
      location.ui_name
    end

    def self.family(flavor, location, family)
      vm_family = Option::VmFamilies.find { it.name == family }

      [
        vm_family.display_name,
        vm_family.ui_descriptor
      ]
    end

    def self.size(flavor, location, family, size)
      size = Option::PostgresSizes.find { it.display_name == size }
      unit_price = BillingRate.unit_price_from_resource_properties("PostgresVCpu", "#{flavor}-#{family}", location.name)

      [
        size.display_name,
        "#{size.vcpu} vCPUs / #{size.memory} GB RAM",
        "$#{"%.2f" % (size.vcpu * unit_price * 60 * 672)}/mo",
        "$#{"%.3f" % (size.vcpu * unit_price * 60)}/hour"
      ]
    end

    def self.storage_size(flavor, location, family, vm_size, storage_size)
      unit_price = BillingRate.unit_price_from_resource_properties("PostgresStorage", flavor, location.name)

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

    def self.ha_type(flavor, location, family, vm_size, storage_size, ha_type)
      vcpu = Option::PostgresSizes.find { it.display_name == vm_size }.vcpu
      ha_type = Option::PostgresHaOptions.find { it.name == ha_type }
      compute_unit_price = BillingRate.unit_price_from_resource_properties("PostgresVCpu", "#{flavor}-#{family}", location.name)
      storage_unit_price = BillingRate.unit_price_from_resource_properties("PostgresStorage", flavor, location.name)
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
      location.ui_name
    end

    def self.cp_nodes(location, cp_nodes)
      cp_node_price = 2 * BillingRate.unit_price_from_resource_properties("KubernetesControlPlaneVCpu", "standard", location.name)
      data = Option::KubernetesCPOptions.find { it.cp_node_count == cp_nodes }
      [
        data.title,
        data.explanation,
        "$#{"%.2f" % (cp_nodes * cp_node_price * 60 * 672)}/mo",
        "$#{"%.3f" % (cp_nodes * cp_node_price * 60)}/hour"
      ]
    end

    def self.worker_size(location, size)
      worker_size = Option::VmSizes.find { it.display_name == size }

      [
        worker_size.display_name,
        "#{worker_size.vcpus} vCPUs / #{worker_size.memory_gib} GB RAM",
        "$#{"%.2f" % monthly_price(location, worker_size)}/mo",
        "$#{"%.3f" % hourly_price(location, worker_size)}/hour"
      ]
    end

    def self.worker_nodes(location, size, worker_nodes)
      worker_size = Option::VmSizes.find { it.display_name == size }

      "#{worker_nodes[:display_name]} - $#{"%.2f" % (worker_nodes[:value] * monthly_price(location, worker_size))}/mo ($#{"%.3f" % (worker_nodes[:value] * hourly_price(location, worker_size))}/hour)"
    end

    def self.node_price(location, worker_size)
      worker_size.vcpus * BillingRate.unit_price_from_resource_properties("KubernetesWorkerVCpu", "standard", location.name) +
        worker_size.storage_size_options.first * BillingRate.unit_price_from_resource_properties("KubernetesWorkerStorage", "standard", location.name)
    end

    def self.hourly_price(location, worker_size)
      node_price(location, worker_size) * 60
    end

    def self.monthly_price(location, worker_size)
      node_price(location, worker_size) * 60 * 672
    end

    def self.version(version)
      "Kubernetes #{version}"
    end
  end

  module PrivateLocation
    def self.select_option(select_option)
      select_option[:display_name]
    end
  end
end
