# frozen_string_literal: true

require "ulid"

class CloverWeb
  hash_branch("vm") do |r|
    @serializer = Serializers::Web::Vm

    r.get true do
      @vms = serialize(Vm.authorized(@current_user.id, "Vm:view").all)

      view "vm/index"
    end

    r.post true do
      project_id = ULID.parse(r.params["project-id"]).to_uuidish
      Authorization.authorize(@current_user.id, "Vm:create", project_id)

      st = Prog::Vm::Nexus.assemble(
        r.params["public-key"],
        project_id,
        name: r.params["name"],
        unix_user: r.params["user"],
        size: r.params["size"],
        location: r.params["location"],
        boot_image: r.params["boot-image"],
        storage_size_gib: r.params["storage-size-gib"].to_i
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "/vm/#{st.vm.ulid}"
    end

    r.on "create" do
      r.get true do
        @projects = Serializers::Web::Project.new(:default).serialize(Project.authorized(@current_user.id, "Vm:create").all)

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
        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        @vm = serialize(vm)

        view "vm/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Vm:delete", vm.id)

        vm.incr_destroy

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
