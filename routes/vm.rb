# frozen_string_literal: true

require "ulid"

class Clover
  hash_branch("vm") do |r|
    @serializer = Serializers::Web::Vm

    r.get true do
      @vms = serialize(Vm.authorized(rodauth.session_value, "Vm:view").all)

      view "vm/index"
    end

    r.post true do
      tag_space_id = ULID.parse(r.params["tag-space-id"]).to_uuidish
      Authorization.authorize(rodauth.session_value, "Vm:create", tag_space_id)

      st = Prog::Vm::Nexus.assemble(
        r.params["public-key"],
        tag_space_id,
        name: r.params["name"],
        unix_user: r.params["user"],
        size: r.params["size"],
        location: r.params["location"],
        boot_image: r.params["boot-image"]
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "/vm/#{st.vm.ulid}"
    end

    r.on "create" do
      r.get true do
        @tag_spaces = Serializers::Web::TagSpace.new(:default).serialize(TagSpace.authorized(rodauth.session_value, "Vm:create").all)

        view "vm/create"
      end
    end

    r.is String do |vm_ulid|
      vm = Vm.from_ulid(vm_ulid)

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(rodauth.session_value, "Vm:view", vm.id)

        @vm = serialize(vm)

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
