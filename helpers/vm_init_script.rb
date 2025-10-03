# frozen_string_literal: true

class Clover
  def vm_init_script_save
    create = @vm_init_script.new?
    handle_validation_failure("vm-init-script/register") do
      flash.now["error"] = "Error #{create ? "registering" : "updating"} virtual machine init script"
    end

    @vm_init_script.name, @vm_init_script.script = typecast_params.nonempty_str(%w[name script])

    DB.transaction do
      @vm_init_script.save_changes
      audit_log(@vm_init_script, create ? "create" : "update")
    end

    flash["notice"] = "Virtual machine init script with name #{@vm_init_script.name} #{create ? "registered" : "updated"}"
    request.redirect "#{@project.path}/vm-init-script"
  end
end
