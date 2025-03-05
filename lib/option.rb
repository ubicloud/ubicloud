# frozen_string_literal: true

require "yaml"

module Option
  ai_models = YAML.load_file("config/ai_models.yml")
  AI_MODELS = ai_models.select { _1["enabled"] }.freeze

  def self.locations(only_visible: true, feature_flags: [])
    Location.all.select { |pl| !only_visible || (pl.visible || feature_flags.include?("location_#{pl.name.tr("-", "_")}")) }
  end

  def self.postgres_locations
    Location.where(name: ["hetzner-fsn1", "leaseweb-wdc02"]).all
  end

  def self.kubernetes_locations
    Location.where(name: ["hetzner-fsn1", "leaseweb-wdc02"]).all
  end

  def self.families(use_slices: false)
    if use_slices
      Option::VmFamilies.select { _1.visible }
    else
      Option::VmFamilies.select { _1.visible && !_1.require_shared_slice }
    end
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-noble", "Ubuntu Noble 24.04 LTS"],
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["debian-12", "Debian 12"],
    ["almalinux-9", "AlmaLinux 9"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmFamily = Data.define(:name, :ui_descriptor, :visible, :require_shared_slice) do
    def display_name
      name.capitalize
    end
  end

  VmFamilies = [
    ["standard", "Dedicated CPU", true, false],
    ["standard-gpu", "Dedicated GPU", false, false],
    ["burstable", "Shared CPU", true, true]
  ].map { |args| VmFamily.new(*args) }

  IoLimits = Struct.new(:max_ios_per_sec, :max_read_mbytes_per_sec, :max_write_mbytes_per_sec)
  NO_IO_LIMITS = IoLimits.new(nil, nil, nil).freeze

  VmSize = Struct.new(:name, :family, :vcpus, :cpu_percent_limit, :cpu_burst_percent_limit, :memory_gib, :storage_size_options, :io_limits, :visible, :gpu, :arch) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16, 30, 60].map {
    storage_size_options = [_1 * 20, _1 * 40]
    VmSize.new("standard-#{_1}", "standard", _1, _1 * 100, 0, _1 * 4, storage_size_options, NO_IO_LIMITS, true, false, "x64")
  }.concat([2, 4, 8, 16, 30, 60].map {
    storage_size_options = [_1 * 20, _1 * 40]
    VmSize.new("standard-#{_1}", "standard", _1, _1 * 100, 0, (_1 * 3.2).to_i, storage_size_options, NO_IO_LIMITS, false, false, "arm64")
  }).concat([6].map {
    VmSize.new("standard-gpu-#{_1}", "standard-gpu", _1, _1 * 100, 0, (_1 * 5.34).to_i, [_1 * 30], NO_IO_LIMITS, false, true, "x64")
  }).concat([1, 2].map {
    storage_size_options = [_1 * 10, _1 * 20]
    io_limits = IoLimits.new(nil, _1 * 50, _1 * 50)
    VmSize.new("burstable-#{_1}", "burstable", _1, _1 * 50, _1 * 50, _1 * 2, storage_size_options, io_limits, true, false, "x64")
  }).concat([1, 2].map {
    storage_size_options = [_1 * 10, _1 * 20]
    io_limits = IoLimits.new(nil, _1 * 50, _1 * 50)
    VmSize.new("burstable-#{_1}", "burstable", _1, _1 * 50, _1 * 50, (_1 * 1.6).to_i, storage_size_options, io_limits, false, false, "arm64")
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
    PostgresHaOption.new(*_1)
  }.freeze

  POSTGRES_VERSION_OPTIONS = {
    PostgresResource::Flavor::STANDARD => ["16", "17"],
    PostgresResource::Flavor::PARADEDB => ["16", "17"],
    PostgresResource::Flavor::LANTERN => ["16"]
  }
end
