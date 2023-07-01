# frozen_string_literal: true

module Option
  BootImage = Struct.new(:name, :display_name)
  VmSize = Struct.new(:name, :display_name, :vcpu, :memory)

  Providers = [
    [Provider::HETZNER, "Hetzner", [
      ["hel1", "Finland"],
      ["fsn1", "Germany"]
    ]],
    [Provider::DATAPACKET, "DataPacket", [
      ["istanbul-mars", "Istanbul"]
    ]]
  ].to_h { |args| [args[0], Provider.new(*args)] }.freeze

  BootImages = [
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9.1", "AlmaLinux 9.1"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSizes = [
    ["c5a.2x", "c5a.2x", 2, 2],
    ["c5a.4x", "c5a.4x", 4, 4],
    ["c5a.6x", "c5a.6x", 6, 6]
  ].map { |args| VmSize.new(*args) }.freeze
end
