# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "vm-init-script") do |r|
    authorize("Project:edit", @project.id)

    r.is do
      r.get do
        if api?
          {items: Serializers::VmInitScript.serialize(@project.vm_init_scripts)}
        else
          view "vm-init-script/index"
        end
      end

      r.post do
        @vm_init_script = VmInitScript.new(project_id: @project.id)
        vm_init_script_save
      end
    end

    r.get web?, "register" do
      @vm_init_script = VmInitScript.new
      view "vm-init-script/register"
    end

    r.is VM_INIT_SCRIPT_NAME_OR_UBID do |name, id|
      @vm_init_script = if name
        @project.vm_init_scripts_dataset.first(name:)
      else
        @project.vm_init_scripts_dataset.with_pk(id)
      end
      check_found_object(@vm_init_script)

      r.get do
        if api?
          Serializers::VmInitScript.serialize(@vm_init_script, detailed: true)
        else
          view "vm-init-script/register"
        end
      end

      r.post do
        vm_init_script_save
      end

      r.delete do
        DB.transaction do
          @vm_init_script.destroy
          audit_log(@vm_init_script, "destroy")
        end

        204
      end
    end
  end
end
