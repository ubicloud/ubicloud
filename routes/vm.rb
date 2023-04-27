# frozen_string_literal: true

require "ulid"

class Clover
  class VmShadow
    attr_accessor :id, :name, :state, :location, :size, :ip6

    def initialize(vm)
      @id = ULID.from_uuidish(vm.id).to_s.downcase
      @name = vm.name
      @state = vm.display_state
      @location = vm.location
      @size = vm.size
      @ip6 = vm.ephemeral_net6&.nth(2)
    end
  end

  hash_branch("vm") do |r|
    r.get true do
      @vms = Vm.map { |vm| VmShadow.new(vm) }

      view "vm/index"
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

    r.on "create" do
      r.get true do
        view "vm/create"
      end
    end

    r.is String do |vm_ulid|
      vm = Vm[id: ULID.parse(vm_ulid).to_uuidish]

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        @vm = VmShadow.new(vm)

        view "vm/show"
      end

      r.delete true do
        vm.incr_destroy
        return "Deleting #{vm.id}"
      end
    end
  end
end
