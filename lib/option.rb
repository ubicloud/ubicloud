# frozen_string_literal: true

require "yaml"

module Option
  ai_models = YAML.load_file("config/ai_models.yml")
  AI_MODELS = ai_models.select { it["enabled"] }.freeze

  def self.locations(only_visible: true, feature_flags: [])
    Location.where(project_id: nil).all.select { |pl| !only_visible || (pl.visible || feature_flags.include?("location_#{pl.name.tr("-", "_")}")) }
  end

  def self.postgres_locations(project_id: nil)
    Location
      .where(Sequel.|(
        {name: ["hetzner-fsn1", "leaseweb-wdc02"]},
        {project_id:}
      )).all
  end

  def self.kubernetes_locations
    Location.where(name: ["hetzner-fsn1", "leaseweb-wdc02"]).all
  end

  def self.kubernetes_versions
    ["v1.32", "v1.33"].freeze
  end

  def self.families
    Option::VmFamilies.select { it.visible }
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-noble", "Ubuntu Noble 24.04 LTS"],
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["debian-12", "Debian 12"],
    ["almalinux-9", "AlmaLinux 9"],
    ["alpine-3.21", "Alpine Linux 3.21"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmFamily = Data.define(:name, :ui_descriptor, :visible, :require_shared_slice) do
    def display_name
      name.capitalize
    end
  end

  VmFamilies = [
    ["standard", "Dedicated CPU", true, false],
    ["standard-gpu", "Dedicated GPU", false, false],
    ["performance", "Dedicated Performance CPU", false, false],
    ["burstable", "Shared CPU", true, true]
  ].map { |args| VmFamily.new(*args) }

  IoLimits = Struct.new(:max_ios_per_sec, :max_read_mbytes_per_sec, :max_write_mbytes_per_sec)
  NO_IO_LIMITS = IoLimits.new(nil, nil, nil).freeze

  VmSize = Struct.new(:name, :family, :vcpus, :cpu_percent_limit, :cpu_burst_percent_limit, :memory_gib, :storage_size_options, :io_limits, :visible, :gpu, :arch) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16, 30, 60].map {
    storage_size_options = [it * 20, it * 40]
    VmSize.new("standard-#{it}", "standard", it, it * 100, 0, it * 4, storage_size_options, NO_IO_LIMITS, true, false, "x64")
  }.concat([2, 4, 8, 16, 30, 60].map {
    storage_size_options = [it * 20, it * 40]
    VmSize.new("standard-#{it}", "standard", it, it * 100, 0, (it * 3.2).to_i, storage_size_options, NO_IO_LIMITS, false, false, "arm64")
  }).concat([6].map {
    VmSize.new("standard-gpu-#{it}", "standard-gpu", it, it * 100, 0, (it * 5.34).to_i, [it * 30], NO_IO_LIMITS, false, true, "x64")
  }).concat([2, 4, 8, 16, 30].map {
    storage_size_options = [it * 20, it * 40]
    VmSize.new("performance-#{it}", "performance", it, it * 100, 0, it * 4, storage_size_options, NO_IO_LIMITS, false, false, "x64")
  }).concat([1, 2].map {
    storage_size_options = [it * 10, it * 20]
    io_limits = IoLimits.new(nil, it * 50, it * 50)
    VmSize.new("burstable-#{it}", "burstable", it, it * 50, it * 50, it * 2, storage_size_options, io_limits, true, false, "x64")
  }).concat([1, 2].map {
    storage_size_options = [it * 10, it * 20]
    io_limits = IoLimits.new(nil, it * 50, it * 50)
    VmSize.new("burstable-#{it}", "burstable", it, it * 50, it * 50, (it * 1.6).to_i, storage_size_options, io_limits, false, false, "arm64")
  }).freeze

  PostgresSize = Struct.new(:location_id, :name, :vm_family, :vm_size, :flavor, :vcpu, :memory, :storage_size_options) do
    alias_method :display_name, :name
  end
  PostgresSizes = Option.postgres_locations.product([2, 4, 8, 16, 30, 60]).flat_map {
    storage_size_options = [_2 * 32, _2 * 64, _2 * 128]
    storage_size_options.map! { |size| size / 15 * 16 } if [30, 60].include?(_2)

    storage_size_limiter = [4096, storage_size_options.last].min.fdiv(storage_size_options.last)
    storage_size_options.map! { |size| size * storage_size_limiter }
    [
      PostgresSize.new(_1.id, "standard-#{_2}", "standard", "standard-#{_2}", PostgresResource::Flavor::STANDARD, _2, _2 * 4, storage_size_options),
      PostgresSize.new(_1.id, "standard-#{_2}", "standard", "standard-#{_2}", PostgresResource::Flavor::PARADEDB, _2, _2 * 4, storage_size_options),
      PostgresSize.new(_1.id, "standard-#{_2}", "standard", "standard-#{_2}", PostgresResource::Flavor::LANTERN, _2, _2 * 4, storage_size_options)
    ]
  }.concat(Option.postgres_locations.product([1, 2]).flat_map {
    storage_size_options = [_2 * 16, _2 * 32, _2 * 64]
    storage_size_options.pop if _1.name == "leaseweb-wdc02"
    [
      PostgresSize.new(_1.id, "burstable-#{_2}", "burstable", "burstable-#{_2}", PostgresResource::Flavor::STANDARD, _2, _2 * 2, storage_size_options),
      PostgresSize.new(_1.id, "burstable-#{_2}", "burstable", "burstable-#{_2}", PostgresResource::Flavor::PARADEDB, _2, _2 * 2, storage_size_options),
      PostgresSize.new(_1.id, "burstable-#{_2}", "burstable", "burstable-#{_2}", PostgresResource::Flavor::LANTERN, _2, _2 * 2, storage_size_options)
    ]
  }).freeze

  PostgresHaOption = Struct.new(:name, :standby_count, :title, :explanation)
  PostgresHaOptions = [[PostgresResource::HaType::NONE, 0, "No Standbys", "No replication"],
    [PostgresResource::HaType::ASYNC, 1, "1 Standby", "Asynchronous replication"],
    [PostgresResource::HaType::SYNC, 2, "2 Standbys", "Synchronous replication with quorum"]].map {
    PostgresHaOption.new(*it)
  }.freeze

  POSTGRES_VERSION_OPTIONS = {
    PostgresResource::Flavor::STANDARD => ["17", "16"],
    PostgresResource::Flavor::PARADEDB => ["17", "16"],
    PostgresResource::Flavor::LANTERN => ["16"]
  }

  AWS_LOCATIONS = ["us-east-1"].freeze

  KubernetesCPOption = Struct.new(:cp_node_count, :title, :explanation)
  KubernetesCPOptions = [[1, "1 Node", "Single control plane node without resilience"],
    [3, "3 Nodes", "Three control plane nodes with resilience"]].map {
    KubernetesCPOption.new(*it)
  }.freeze

  def self.customer_postgres_sizes_for_project(project_id)
    return Option::PostgresSizes unless project_id

    customer_locations = Location.where(project_id:).all
    (
      Option::PostgresSizes +
      customer_locations.product([2, 4, 8, 16, 30, 60]).flat_map { |location, size|
        storage_size_options = [(size * 59.375).to_i]

        Option::PostgresSize.new(location.id, "standard-#{size}", "standard", "standard-#{size}", PostgresResource::Flavor::STANDARD, size, size * 4, storage_size_options)
      }
    )
  end
end
