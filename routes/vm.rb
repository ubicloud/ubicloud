# frozen_string_literal: true

require "ulid"

class Clover
  class VmShadow
    attr_accessor :id, :raw_id, :name, :state, :location, :size, :ip6, :tag_spaces

    def initialize(vm)
      @id = ULID.from_uuidish(vm.id).to_s.downcase
      @raw_id = vm.id
      @name = vm.name
      @state = vm.display_state
      @location = vm.location
      @size = vm.size
      @ip6 = vm.ephemeral_net6&.nth(2)
      @tag_spaces = vm.tag_spaces.map { TagSpaceShadow.new(_1) }
    end
  end

  hash_branch("vm") do |r|
    r.get true do
      @vms = Vm.authorized(rodauth.session_value, "Vm:view").map { VmShadow.new(_1) }

      view "vm/index"
    end

    r.post true do
      tag_space_id = ULID.parse(r.params["tag-space-id"]).to_uuidish
      Authorization.authorize(rodauth.session_value, "Vm:create", tag_space_id)

      Prog::Vm::Nexus.assemble(
        r.params["public-key"],
        tag_space_id,
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
        @tag_spaces = TagSpace.authorized(rodauth.session_value, "Vm:create").map { TagSpaceShadow.new(_1) }

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
        Authorization.authorize(rodauth.session_value, "Vm:view", vm.id)

        @vm = VmShadow.new(vm)

        view "vm/show"
      end

      r.delete true do
        Authorization.authorize(rodauth.session_value, "Vm:delete", vm.id)

        vm.incr_destroy

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
