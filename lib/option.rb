# frozen_string_literal: true

module Option
  Location = Struct.new(:name, :display_name)
  BootImage = Struct.new(:name, :display_name)
  VmSize = Struct.new(:name, :display_name, :vcpu, :memory, :disk)

  Locations = [
    ["hetzner-hel1", "Hetzner Helsinki"],
    ["hetzner-nbg1", "Hetzner Nuremberg"],
    ["equinix-da11", "Equinix Dallas 11"],
    ["equinix-ist", "Equinix Istanbul"],
    ["aws-centraleu1", "AWS Frankfurt"],
    ["aws-apsoutheast2", "AWS Sydney"]
  ].map { |args| Location.new(*args) }.freeze

  BootImages = [
    ["ubuntu-jammy", "Ubuntu Jammy 22.04 LTS"],
    ["almalinux-9.1", "AlmaLinux 9.1"],
    ["opensuse-leap-15.4", "openSUSE Leap 15.4"]
  ].map { |args| BootImage.new(*args) }.freeze

  VmSizes = [
    ["standard-1", "Standard 1", 1, 2, 160],
    ["standard-2", "Standard 2", 2, 4, 256],
    ["standard-3", "Standard 3", 4, 8, 512],
    ["standard-4", "Standard 4", 8, 16, 512]
  ].map { |args| VmSize.new(*args) }.freeze
end
