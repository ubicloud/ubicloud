# frozen_string_literal: true

class Clover
  def ssh_public_key_save
    create = @ssh_public_key.new?
    handle_validation_failure("ssh-public-key/register") do
      flash.now["error"] = "Error #{create ? "registering" : "updating"} SSH public key"
    end

    @ssh_public_key.name, @ssh_public_key.public_key = typecast_params.nonempty_str(%w[name public_key])

    DB.transaction do
      @ssh_public_key.save_changes
      audit_log(@ssh_public_key, create ? "create" : "update")
    end

    flash["notice"] = "SSH public key with name #{@ssh_public_key.name} #{create ? "registered" : "updated"}"
    request.redirect "#{@project.path}/ssh-public-key"
  end
end
