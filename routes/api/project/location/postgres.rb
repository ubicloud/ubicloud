# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.get true do
      result = @project.postgres_resources_dataset.where(location: @location).authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Postgres.serialize(result[:records]),
        count: result[:count]
      }
    end

    r.on "id" do
      r.on String do |pg_ubid|
        pg = PostgresResource.from_ubid(pg_ubid)

        if pg&.location != @location
          pg = nil
        end

        handle_pg_requests(@current_user, pg, @project)
      end
    end

    r.on String do |pg_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?
        Validation.validate_postgres_location(@location)

        required_parameters = ["size"]
        allowed_optional_parameters = ["storage_size", "ha_type"]

        request_body_params = Validation.validate_request_body(r.body.read, required_parameters, allowed_optional_parameters)
        parsed_size = Validation.validate_postgres_size(request_body_params["size"])
        st = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: @project.id,
          location: @location,
          name: pg_name,
          target_vm_size: parsed_size.vm_size,
          target_storage_size_gib: request_body_params["storage_size"] || parsed_size.storage_size_options.first,
          ha_type: request_body_params["ha_type"] || PostgresResource::HaType::NONE
        )

        Serializers::Postgres.serialize(st.subject, {detailed: true})
      end

      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first
      handle_pg_requests(@current_user, pg, @project)
    end
  end

  def handle_pg_requests(user, pg, project)
    unless pg
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      Authorization.authorize(user.id, "Postgres:view", pg.id)
      Serializers::Postgres.serialize(pg, {detailed: true})
    end

    request.delete true do
      Authorization.authorize(user.id, "Postgres:delete", pg.id)
      pg.incr_destroy

      response.status = 204
      request.halt
    end

    request.on "firewall-rule" do
      request.post true do
        Authorization.authorize(user.id, "Postgres:Firewall:edit", pg.id)

        required_parameters = ["cidr"]

        request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

        Validation.validate_cidr(request_body_params["cidr"])

        DB.transaction do
          PostgresFirewallRule.create_with_id(
            postgres_resource_id: pg.id,
            cidr: request_body_params["cidr"]
          )
          pg.incr_update_firewall_rules
        end

        Serializers::Postgres.serialize(pg, {detailed: true})
      end

      request.get true do
        Authorization.authorize(user.id, "Postgres:Firewall:view", pg.id)
        Serializers::PostgresFirewallRule.serialize(pg.firewall_rules)
      end

      request.is String do |firewall_rule_ubid|
        request.delete true do
          Authorization.authorize(user.id, "Postgres:Firewall:edit", pg.id)
          fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid)

          if fwr
            DB.transaction do
              fwr.destroy
              pg.incr_update_firewall_rules
            end
          end

          response.status = 204
          request.halt
        end
      end
    end

    request.post "restore" do
      Authorization.authorize(user.id, "Postgres:create", project.id)
      Authorization.authorize(user.id, "Postgres:view", pg.id)

      required_parameters = ["name", "restore_target"]

      request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

      st = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location: pg.location,
        name: request_body_params["name"],
        target_vm_size: pg.target_vm_size,
        target_storage_size_gib: pg.target_storage_size_gib,
        parent_id: pg.id,
        restore_target: request_body_params["restore_target"]
      )

      Serializers::Postgres.serialize(st.subject, {detailed: true})
    end

    request.post "reset-superuser-password" do
      Authorization.authorize(user.id, "Postgres:create", project.id)
      Authorization.authorize(user.id, "Postgres:view", pg.id)

      unless pg.representative_server.primary?
        fail CloverError.new(400, "InvalidRequest", "Superuser password cannot be updated during restore!")
      end

      required_parameters = ["password"]

      request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

      Validation.validate_postgres_superuser_password(request_body_params["password"])

      DB.transaction do
        pg.update(superuser_password: request_body_params["password"])
        pg.representative_server.incr_update_superuser_password
      end

      Serializers::Postgres.serialize(pg, {detailed: true})
    end

    request.post "failover" do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

      unless pg.representative_server.primary?
        fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered during restore!")
      end

      unless @project.get_ff_postgresql_base_image
        fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered for this resource!")
      end

      unless pg.representative_server.trigger_failover
        fail CloverError.new(400, "InvalidRequest", "There is not a suitable standby server to failover!")
      end

      Serializers::Postgres.serialize(pg, {detailed: true})
    end
  end
end
