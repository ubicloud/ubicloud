# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "ssh-public-key") do |r|
    authorize("Project:edit", @project.id)

    r.is do
      r.get do
        if api?
          {items: Serializers::SshPublicKey.serialize(@project.ssh_public_keys)}
        else
          view "ssh-public-key/index"
        end
      end

      r.post do
        @ssh_public_key = SshPublicKey.new(project_id: @project.id)
        ssh_public_key_save
      end
    end

    r.get web?, "register" do
      @ssh_public_key = SshPublicKey.new
      view "ssh-public-key/register"
    end

    r.is SSH_PUBLIC_KEY_NAME_OR_UBID do |name, id|
      @ssh_public_key = if name
        @project.ssh_public_keys_dataset.first(name:)
      else
        @project.ssh_public_keys_dataset.with_pk(id)
      end
      check_found_object(@ssh_public_key)

      r.get do
        if api?
          Serializers::SshPublicKey.serialize(@ssh_public_key, detailed: true)
        else
          view "ssh-public-key/register"
        end
      end

      r.post do
        ssh_public_key_save
      end

      r.delete do
        DB.transaction do
          @ssh_public_key.destroy
          audit_log(@ssh_public_key, "destroy")
        end

        204
      end
    end
  end
end
