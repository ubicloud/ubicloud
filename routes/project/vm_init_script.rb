# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "vm-init-script") do |r|
    r.web do
      authorize("Project:edit", @project.id)

      r.is do
        r.get do
          view "vm-init-script/index"
        end

        r.post do
          @vm_init_script = VmInitScript.new(project_id: @project.id)
          vm_init_script_save
        end
      end

      r.is :ubid_uuid do |uuid|
        next unless (@vm_init_script = @project.vm_init_scripts_dataset.with_pk(uuid))

        r.get do
          view "vm-init-script/register"
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

      r.get "register" do
        @vm_init_script = VmInitScript.new
        view "vm-init-script/register"
      end
    end
  end
end
