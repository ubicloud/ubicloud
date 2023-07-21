# frozen_string_literal: true

module Option
  Provider = Struct.new(:name, :display_name) do
    self::HETZNER = "hetzner"
    self::DATAPACKET = "dp"
  end
  Providers = [
    [Provider::HETZNER, "Hetzner"],
    [Provider::DATAPACKET, "DataPacket"]
  ].map { |args| [args[0], Provider.new(*args)] }.to_h.freeze

  Location = Struct.new(:provider, :name, :display_name)
  Locations = [
    [Providers[Provider::HETZNER], "hetzner-hel1", "Finland"],
    [Providers[Provider::HETZNER], "hetzner-fsn1", "Germany"],
    [Providers[Provider::DATAPACKET], "dp-istanbul-mars", "Istanbul"]
  ].map { |args| Location.new(*args) }.freeze

  def self.locations_for_provider(provider)
    Option::Locations.select { provider.nil? || _1.provider.name == provider }
  end

  BootImage = Struct.new(:name, :display_name)
  BootImages = [
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9.1", "AlmaLinux 9.1"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSize = Struct.new(:name, :display_name, :vcpu, :memory)
  VmSizes = [
    ["c5a.2x", "c5a.2x", 2, 2],
    ["c5a.4x", "c5a.4x", 4, 4],
    ["c5a.6x", "c5a.6x", 6, 6]
  ].map { |args| VmSize.new(*args) }.freeze
end
