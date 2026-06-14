# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "secret-store") do |r|
    r.is do
      r.get true do
        dataset = dataset_authorize(@project.secret_stores_dataset, "SecretStore:view")
        if api?
          {items: Serializers::SecretStore.serialize(dataset.all)}
        else
          @secret_stores = dataset.all
          view "secret-store/index"
        end
      end

      r.post true do
        authorize("SecretStore:create", @project)
        handle_validation_failure("secret-store/create")
        name = typecast_params.nonempty_str!("name")
        description = typecast_params.nonempty_str("description")

        secret_store = nil
        DB.transaction do
          secret_store = SecretStore.create(project_id: @project.id, name:, description:)
          audit_log(secret_store, "create")
        end

        if api?
          Serializers::SecretStore.serialize(secret_store)
        else
          flash["notice"] = "Secret store '#{name}' created"
          r.redirect "#{@project.path}#{secret_store.path}"
        end
      end
    end

    r.get web?, "create" do
      authorize("SecretStore:create", @project)
      view "secret-store/create"
    end

    r.on SECRET_STORE_NAME_OR_UBID do |name, id|
      secret_store = if name
        @project.secret_stores_dataset.first(name:)
      else
        @project.secret_stores_dataset.with_pk(id)
      end
      @secret_store = secret_store
      check_found_object(secret_store)

      r.get true do
        authorize("SecretStore:view", secret_store)
        if api?
          Serializers::SecretStore.serialize(secret_store, detailed: true)
        else
          view "secret-store/show"
        end
      end

      r.post true do
        authorize("SecretStore:edit", secret_store)
        handle_validation_failure("secret-store/show")
        new_name = typecast_params.nonempty_str("name")
        description = typecast_params.nonempty_str("description")

        DB.transaction do
          secret_store.name = new_name if new_name
          secret_store.description = description if description
          secret_store.save_changes
          audit_log(secret_store, "update")
        end

        if api?
          Serializers::SecretStore.serialize(secret_store)
        else
          flash["notice"] = "Secret store updated"
          r.redirect "#{@project.path}#{secret_store.path}"
        end
      end

      r.delete true do
        authorize("SecretStore:delete", secret_store)
        DB.transaction do
          secret_store.destroy
          audit_log(secret_store, "destroy")
        end

        if api?
          204
        else
          flash["notice"] = "Secret store deleted"
          r.redirect "#{@project.path}/secret-store"
        end
      end

      r.on "secret" do
        r.get api? do
          authorize("SecretStore:view", secret_store)
          {items: Serializers::Secret.serialize(secret_store.secrets)}
        end

        r.post true do
          authorize("SecretStore:edit", secret_store)
          handle_validation_failure("secret-store/show")
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

          if api?
            Serializers::Secret.serialize(secret, detailed: true)
          else
            flash["notice"] = "Secret '#{key}' saved"
            r.redirect "#{@project.path}#{secret_store.path}"
          end
        end

        r.on(String) do |key|
          r.get api? do
            authorize("SecretStore:view", secret_store)
            secret = secret_store.secrets_dataset.first(key:)
            check_found_object(secret)
            Serializers::Secret.serialize(secret, detailed: true)
          end

          r.delete true do
            authorize("SecretStore:edit", secret_store)
            secret = secret_store.secrets_dataset.first(key:)
            check_found_object(secret)
            DB.transaction do
              secret.destroy
              audit_log(secret, "destroy")
            end

            if api?
              204
            else
              flash["notice"] = "Secret '#{key}' deleted"
              r.redirect "#{@project.path}#{secret_store.path}"
            end
          end
        end
      end
    end
  end
end
