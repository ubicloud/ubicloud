# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "secret-store") do |r|
    # Web UI branches are added in a follow-up; for now only the JSON API is served.
    r.get api? do
      dataset = dataset_authorize(@project.secret_stores_dataset, "SecretStore:view")
      {items: Serializers::SecretStore.serialize(dataset.all)}
    end

    r.post api? do
      authorize("SecretStore:create", @project)
      name = typecast_params.nonempty_str!("name")
      description = typecast_params.nonempty_str("description")

      secret_store = nil
      DB.transaction do
        secret_store = SecretStore.create(project_id: @project.id, name:, description:)
        audit_log(secret_store, "create")
      end

      Serializers::SecretStore.serialize(secret_store)
    end

    r.on SECRET_STORE_NAME_OR_UBID do |name, id|
      secret_store = if name
        @project.secret_stores_dataset.first(name:)
      else
        @project.secret_stores_dataset.with_pk(id)
      end
      check_found_object(secret_store)

      r.is do
        r.get api? do
          authorize("SecretStore:view", secret_store)
          Serializers::SecretStore.serialize(secret_store, detailed: true)
        end

        r.post api? do
          authorize("SecretStore:edit", secret_store)
          new_name = typecast_params.nonempty_str("name")
          description = typecast_params.nonempty_str("description")

          DB.transaction do
            secret_store.name = new_name if new_name
            secret_store.description = description if description
            secret_store.save_changes
            audit_log(secret_store, "update")
          end

          Serializers::SecretStore.serialize(secret_store)
        end

        r.delete api? do
          authorize("SecretStore:delete", secret_store)
          DB.transaction do
            secret_store.destroy
            audit_log(secret_store, "destroy")
          end
          204
        end
      end

      r.on "secret" do
        r.is do
          r.get api? do
            authorize("SecretStore:view", secret_store)
            {items: Serializers::Secret.serialize(secret_store.secrets)}
          end

          r.post api? do
            authorize("SecretStore:edit", secret_store)
            key = typecast_params.nonempty_str!("key")
            value = typecast_params.nonempty_str!("value")

            secret = nil
            DB.transaction do
              if (secret = secret_store.secrets_dataset.first(key:))
                secret.update(value:, updated_at: Time.now)
                audit_log(secret, "update")
              else
                secret = secret_store.add_secret(key:, value:)
                audit_log(secret, "create")
              end
            end

            Serializers::Secret.serialize(secret, detailed: true)
          end
        end

        r.on(String) do |key|
          r.get api? do
            authorize("SecretStore:view", secret_store)
            secret = secret_store.secrets_dataset.first(key:)
            check_found_object(secret)
            Serializers::Secret.serialize(secret, detailed: true)
          end

          r.delete api? do
            authorize("SecretStore:edit", secret_store)
            secret = secret_store.secrets_dataset.first(key:)
            check_found_object(secret)
            DB.transaction do
              secret.destroy
              audit_log(secret, "destroy")
            end
            204
          end
        end
      end
    end
  end
end
