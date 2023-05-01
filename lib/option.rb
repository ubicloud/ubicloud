# frozen_string_literal: true

module Option
  Location = Struct.new(:name, :display_name)
  BootImage = Struct.new(:name, :display_name)
  VmSize = Struct.new(:name, :display_name, :vcpu, :memory, :disk)

  Locations = [
    ["hetzner-hel1", "Hetzner Finland"],
    ["hetzner-fsn1", "Hetzner Germany"],
    ["equinix-da11", "Equinix Dallas"]
  ].map { |args| Location.new(*args) }.freeze

  BootImages = [
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9.1", "AlmaLinux 9.1"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSizes = [
    ["m5a.2x", "m5a.2x", 2, 4, 30],
    ["m5a.4x", "m5a.4x", 4, 8, 60],
    ["m5a.6x", "m5a.6x", 6, 12, 90],
    ["c5a.2x", "c5a.2x", 2, 2, 30],
    ["c5a.6x", "c5a.6x", 6, 6, 90]
  ].map { |args| VmSize.new(*args) }.freeze
end
