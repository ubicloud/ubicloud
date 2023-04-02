# frozen_string_literal: true

require "ulid"

class Clover
  PageVm = Struct.new(:id, :name, :state, :ip6, keyword_init: true)

  hash_branch("vm") do |r|
    r.get true do
      @data = Vm.map { |vm|
        PageVm.new(id: ULID.from_uuidish(vm.id).to_s.downcase,
          name: vm.name,
          state: vm.display_state,
          ip6: vm.ephemeral_net6&.network)
      }

      view "vm/index"
    end
  
    r.on "create" do
      r.get true do
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

        r.redirect "/vm"
      end
    end

    r.is String do |vm_ulid|
      vm = Vm[id: ULID.parse(vm_ulid).to_uuidish]

      r.get true do
        @vm = PageVm.new(id: vm_ulid,
          name: vm.name,
          state: vm.display_state,
          ip6: vm.ephemeral_net6&.network)
        
        view "vm/show"
      end

      r.delete true do
        return "Deleting #{vm.id}"
      end
    end
  end
end
