# frozen_string_literal: true

module Option
  Provider = Struct.new(:name, :display_name) do
    self::HETZNER = "hetzner"
  end
  Providers = [
    [Provider::HETZNER, "Hetzner"]
  ].map { |args| [args[0], Provider.new(*args)] }.to_h.freeze

  Location = Struct.new(:provider, :name, :display_name, :visible)
  Locations = [
    [Providers[Provider::HETZNER], "hetzner-hel1", "Finland", true],
    [Providers[Provider::HETZNER], "hetzner-fsn1", "Germany", true],
    [Providers[Provider::HETZNER], "github-runners", "GitHub Runner", false]
  ].map { |args| Location.new(*args) }.freeze

  def self.locations_for_provider(provider, only_visible: true)
    Option::Locations.select { (!only_visible || _1.visible) && (provider.nil? || _1.provider.name == provider) }
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9.1", "AlmaLinux 9.1"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSize = Struct.new(:name, :family, :vcpu, :memory, :storage_size_gib) do
    alias_method :display_name, :name
  end
  VmSizes = [2, 4, 8, 16].map {
    VmSize.new("standard-#{_1}", "standard", _1, _1 * 4, (_1 / 2) * 25)
  }.freeze
end
