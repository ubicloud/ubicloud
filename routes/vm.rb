# frozen_string_literal: true

require "ulid"

class Clover
  PageVm = Struct.new(:id, :name, :state, :ip6, :location, :size, keyword_init: true)
  LocationOption = Struct.new(:name, :display_name)
  ImageOption = Struct.new(:name, :display_name)
  SizeOption = Struct.new(:name, :display_name, :vcpu, :memory, :disk, :low_price, :high_price)

  hash_branch("vm") do |r|
    r.get true do
      @data = Vm.map { |vm|
        PageVm.new(id: ULID.from_uuidish(vm.id).to_s.downcase,
          name: vm.name,
          state: vm.display_state,
          location: vm.location,
          size: vm.size,
          ip6: vm.ephemeral_net6&.network)
      }

      view "vm/index"
    end

    r.on "create" do
      r.get true do
        @locations = [
          LocationOption.new(name: "hetzner-hel1", display_name: "Hetzner Helsinki"),
          LocationOption.new(name: "hetzner-nbg1", display_name: "Hetzner Nuremberg"),
          LocationOption.new(name: "equinix-da11", display_name: "Equinix Dallas 11"),
          LocationOption.new(name: "equinix-ist", display_name: "Equinix Istanbul"),
          LocationOption.new(name: "aws-centraleu1", display_name: "AWS Frankfurt"),
          LocationOption.new(name: "aws-apsoutheast2", display_name: "AWS Sydney")
        ]

        @images = [
          ImageOption.new(name: "ubuntu-jammy", display_name: "Ubuntu Jammy 22.04 LTS"),
          ImageOption.new(name: "almalinux-9.1", display_name: "AlmaLinux 9.1"),
          ImageOption.new(name: "debian-11", display_name: "Debian 11")
        ]

        @sizes = [
          SizeOption.new(name: "standard-1", display_name: "Standard 1", vcpu: 1, memory: 2, disk: 160, low_price: 8, high_price: 12),
          SizeOption.new(name: "standard-2", display_name: "Standard 2", vcpu: 2, memory: 4, disk: 256, low_price: 10, high_price: 25),
          SizeOption.new(name: "standard-4", display_name: "Standard 4", vcpu: 4, memory: 8, disk: 512, low_price: 40, high_price: 60),
          SizeOption.new(name: "memory-4", display_name: "Memory Optimized 4", vcpu: 4, memory: 16, disk: 512, low_price: 65, high_price: 80),
          SizeOption.new(name: "memory-8", display_name: "Memory Optimized 8", vcpu: 8, memory: 32, disk: 1024, low_price: 120, high_price: 180)
        ]

        view "vm/create"
      end

      r.post true do
        Prog::Vm::Nexus.assemble(
          r.params["public-key"],
          name: r.params["name"],
          unix_user: r.params["user"],
          size: r.params["size"],
          location: r.params["location"],
          boot_image: r.params["boot-image"]
        )

        flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

        r.redirect "/vm"
      end
    end

    r.is String do |vm_ulid|
      vm = Vm[id: ULID.parse(vm_ulid).to_uuidish]

      r.get true do
        @vm = PageVm.new(id: vm_ulid,
          name: vm.name,
          state: vm.display_state,
          location: vm.location,
          size: vm.size,
          ip6: vm.ephemeral_net6&.network)

        view "vm/show"
      end

      r.delete true do
        return "Deleting #{vm.id}"
      end
    end
  end
end
