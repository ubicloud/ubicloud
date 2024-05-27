# frozen_string_literal: true

require "yaml"

module Option
  providers = YAML.load_file("config/providers.yml")

  Provider = Struct.new(:name, :display_name)
  Location = Struct.new(:provider, :name, :display_name, :visible)

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
        location["visible"]
      ))
    end
  end

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
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSize = Struct.new(:name, :family, :vcpu, :memory, :min_storage_size_gib, :max_storage_size_gib, :storage_size_step_gib, :visible, :gpu) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16, 30, 60].map {
    VmSize.new("standard-#{_1}", "standard", _1, _1 * 4, (_1 / 2) * 40, _1 * 40, (_1 / 2) * 20, true, false)
  }.concat([6].map {
    VmSize.new("standard-gpu-#{_1}", "standard-gpu", _1, (_1 * 5.34).to_i, (_1 / 2) * 60, _1 * 60, (_1 / 2) * 60, false, true)
  }).freeze

  PostgresSize = Struct.new(:name, :vm_size, :family, :vcpu, :memory, :min_storage_size_gib, :max_storage_size_gib, :storage_size_step_gib) do
    alias_method :display_name, :name
  end
  PostgresSizes = [2, 4, 8, 16, 30, 60].map {
    PostgresSize.new("standard-#{_1}", "standard-#{_1}", "standard", _1, _1 * 4, _1 * 64, _1 * 256, _1 * 64)
  }.freeze

  PostgresHaOption = Struct.new(:name, :standby_count, :title, :explanation)
  PostgresHaOptions = [[PostgresResource::HaType::NONE, 0, "No Standbys", "No replication"],
    [PostgresResource::HaType::ASYNC, 1, "1 Standby", "Asyncronous replication"],
    [PostgresResource::HaType::SYNC, 2, "2 Standbys", "Syncronous replication with quorum"]].map {
    PostgresHaOption.new(*_1)
  }.freeze
end
