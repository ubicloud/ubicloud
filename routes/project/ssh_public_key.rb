# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "ssh-public-key") do |r|
    r.web do
      authorize("Project:edit", @project.id)

      r.is do
        r.get do
          view "ssh-public-key/index"
        end

        r.post do
          @ssh_public_key = SshPublicKey.new(project_id: @project.id)
          ssh_public_key_save
        end
      end

      r.is :ubid_uuid do |uuid|
        next unless (@ssh_public_key = @project.ssh_public_keys_dataset.with_pk(uuid))

        r.get do
          view "ssh-public-key/register"
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

      r.get "register" do
        @ssh_public_key = SshPublicKey.new
        view "ssh-public-key/register"
      end
    end
  end
end
