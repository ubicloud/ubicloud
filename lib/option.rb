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

  def self.locations(only_visible: true)
    Option::LOCATIONS.select { !only_visible || _1.visible }
  end

  def self.postgres_locations
    Option::LOCATIONS.select { _1.name == "hetzner-fsn1" }
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-noble", "Ubuntu Noble 24.04 LTS"],
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9", "AlmaLinux 9"],
    ["almalinux-8", "AlmaLinux 8"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSize = Struct.new(:name, :family, :vcpu, :memory, :storage_size_options, :visible, :gpu) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16, 30, 60].map {
    storage_size_options = [_1 * 20, _1 * 40]
    VmSize.new("standard-#{_1}", "standard", _1, _1 * 4, storage_size_options, true, false)
  }.concat([6].map {
    VmSize.new("standard-gpu-#{_1}", "standard-gpu", _1, (_1 * 5.34).to_i, [_1 * 30], false, true)
  }).freeze

  PostgresSize = Struct.new(:name, :vm_size, :family, :vcpu, :memory, :storage_size_options) do
    alias_method :display_name, :name
  end
  PostgresSizes = [2, 4, 8, 16, 30, 60].flat_map {
    storage_size_options = [_1 * 64, _1 * 128, _1 * 256]
    storage_size_options = [1024, 2048, 4096] if [30, 60].include?(_1)
    [
      PostgresSize.new("standard-#{_1}", "standard-#{_1}", PostgresResource::Flavor::STANDARD, _1, _1 * 4, storage_size_options),
      PostgresSize.new("standard-#{_1}", "standard-#{_1}", PostgresResource::Flavor::PARADEDB, _1, _1 * 4, storage_size_options)
    ]
  }.freeze

  PostgresHaOption = Struct.new(:name, :standby_count, :title, :explanation)
  PostgresHaOptions = [[PostgresResource::HaType::NONE, 0, "No Standbys", "No replication"],
    [PostgresResource::HaType::ASYNC, 1, "1 Standby", "Asynchronous replication"],
    [PostgresResource::HaType::SYNC, 2, "2 Standbys", "Synchronous replication with quorum"]].map {
    PostgresHaOption.new(*_1)
  }.freeze
end
