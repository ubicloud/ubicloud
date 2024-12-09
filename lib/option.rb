# frozen_string_literal: true

require "yaml"

module Option
  ai_models = YAML.load_file("config/ai_models.yml")
  providers = YAML.load_file("config/providers.yml")

  Provider = Struct.new(:name, :display_name)
  Location = Struct.new(:provider, :name, :display_name, :ui_name, :visible)

  PROVIDERS = {}
  LOCATIONS = []

  providers.each do |provider|
    provider_internal_name = provider["provider_internal_name"]
    PROVIDERS[provider_internal_name] = Provider.new(provider_internal_name, provider["provider_display_name"])
    Provider.const_set(provider_internal_name.gsub(/[^a-zA-Z]/, "_").upcase, provider_internal_name)

    provider["locations"].each do |location|
      LOCATIONS.push(Location.new(
        PROVIDERS[provider_internal_name],
        location["internal_name"],
        location["display_name"],
        location["ui_name"],
        location["visible"]
      ))
    end
  end

  AI_MODELS = ai_models.select { _1["enabled"] }.freeze
  PROVIDERS.freeze
  LOCATIONS.freeze

  def self.locations(only_visible: true, feature_flags: [])
    Option::LOCATIONS.select { !only_visible || (_1.visible || feature_flags.include?("location_#{_1.name.tr("-", "_")}")) }
  end

  def self.postgres_locations
    Option::LOCATIONS.select { _1.name == "hetzner-fsn1" || _1.name == "leaseweb-wdc02" }
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-noble", "Ubuntu Noble 24.04 LTS"],
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["debian-12", "Debian 12"],
    ["almalinux-9", "AlmaLinux 9"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmFamily = Struct.new(:name, :can_share_slice, :slice_overcommit_factor)
  VmFamilies = [
    ["standard", false, 1],
    ["standard-gpu", false, 1],
    ["burstable", true, 1],
    ["basic", true, 4]
  ].map { |args| VmFamily.new(*args) }.freeze

  IoLimits = Struct.new(:max_ios_per_sec, :max_read_mbytes_per_sec, :max_write_mbytes_per_sec)
  NO_IO_LIMITS = IoLimits.new(nil, nil, nil).freeze

  VmSize = Struct.new(:name, :family, :cores, :vcpus, :vcpu_percent_limit, :vcpu_burst_percent_limit, :memory_gib, :storage_size_options, :io_limits, :visible, :gpu, :arch) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16, 30, 60].map {
    storage_size_options = [_1 * 20, _1 * 40]
    VmSize.new("standard-#{_1}", "standard", _1 / 2, _1, _1 * 100, 0, _1 * 4, storage_size_options, NO_IO_LIMITS, true, false, "x64")
  }.concat([2, 4, 8, 16, 30, 60].map {
    storage_size_options = [_1 * 20, _1 * 40]
    VmSize.new("standard-#{_1}", "standard", _1, _1, _1 * 100, 0, (_1 * 3.2).to_i, storage_size_options, NO_IO_LIMITS, false, false, "arm64")
  }).concat([6].map {
    VmSize.new("standard-gpu-#{_1}", "standard-gpu", _1 / 2, _1, _1 * 100, _1, (_1 * 5.34).to_i, [_1 * 30], NO_IO_LIMITS, false, true, "x64")
  }).concat([[2, 50], [2, 100]].map {
    storage_size_options = [_1[1] * 20 / 100, _1[1] * 40 / 100]
    VmSize.new("burstable-#{_1[0]}x#{_1[1] * 4 / 100}", "burstable", _1[0] / 2, _1[0], _1[1], _1[1], _1[1] * 4 / 100, storage_size_options, NO_IO_LIMITS, false, false, "x64")
  }).concat([[2, 50], [2, 100]].map {
    storage_size_options = [_1[1] * 20 / 100, _1[1] * 40 / 100]
    VmSize.new("burstable-#{_1[0]}x#{_1[1] * 4 / 100}", "burstable", _1[0], _1[0], _1[1], _1[1], (_1[1] * 3.2 / 100).to_i, storage_size_options, NO_IO_LIMITS, false, false, "arm64")
  }).concat([[2, 100], [2, 200]].map {
    storage_size_options = [_1[1] * 10 / 100, _1[1] * 20 / 100]
    VmSize.new("basic-#{_1[0]}x#{_1[1] / 100}", "basic", _1[0], _1[0], _1[1], 0, _1[1] / 100, storage_size_options, NO_IO_LIMITS, false, false, "x64")
  }).concat([[2, 100], [2, 200]].map {
    storage_size_options = [_1[1] * 10 / 100, _1[1] * 20 / 100]
    VmSize.new("basic-#{_1[0]}x#{_1[1] / 100}", "basic", _1[0] * 2, _1[0], _1[1], 0, (_1[1] * 0.8 / 100).to_i, storage_size_options, NO_IO_LIMITS, false, false, "arm64")
  }).freeze

  PostgresSize = Struct.new(:location, :name, :vm_size, :family, :vcpu, :memory, :storage_size_options) do
    alias_method :display_name, :name
  end
  PostgresSizes = Option.postgres_locations.product([2, 4, 8, 16, 30, 60]).flat_map {
    storage_size_options = [_2 * 64, _2 * 128, _2 * 256]
    storage_size_options.map! { |size| size / 15 * 16 } if [30, 60].include?(_2)

    storage_size_options.pop if _1.name == "leaseweb-wdc02"

    storage_size_limiter = [4096, storage_size_options.last].min.fdiv(storage_size_options.last)
    storage_size_options.map! { |size| size * storage_size_limiter }
    [
      PostgresSize.new(_1.name, "standard-#{_2}", "standard-#{_2}", PostgresResource::Flavor::STANDARD, _2, _2 * 4, storage_size_options),
      PostgresSize.new(_1.name, "standard-#{_2}", "standard-#{_2}", PostgresResource::Flavor::PARADEDB, _2, _2 * 4, storage_size_options),
      PostgresSize.new(_1.name, "standard-#{_2}", "standard-#{_2}", PostgresResource::Flavor::LANTERN, _2, _2 * 4, storage_size_options)
    ]
  }.freeze

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
