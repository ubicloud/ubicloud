# frozen_string_literal: true

class Clover
  def ssh_public_key_save
    create = @ssh_public_key.new?
    handle_validation_failure("ssh-public-key/register") do
      flash.now["error"] = "Error #{create ? "registering" : "updating"} SSH public key"
    end

    name, public_key = typecast_params.nonempty_str(%w[name public_key])
    if create || web?
      @ssh_public_key.name = name
      @ssh_public_key.public_key = public_key
    else
      @ssh_public_key.name = name if name
      @ssh_public_key.public_key = public_key if public_key
    end

    DB.transaction do
      @ssh_public_key.save_changes
      audit_log(@ssh_public_key, create ? "create" : "update")
    end

    if api?
      Serializers::SshPublicKey.serialize(@ssh_public_key, detailed: true)
    else
      flash["notice"] = "SSH public key with name #{@ssh_public_key.name} #{create ? "registered" : "updated"}"
      request.redirect "#{@project.path}/ssh-public-key"
    end
  end
end
