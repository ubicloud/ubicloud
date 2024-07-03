# frozen_string_literal: true

class Routes::Common::PostgresHelper < Routes::Common::Base
  def list
    if @mode == AppMode::API
      dataset = project.postgres_resources_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(@user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::Postgres.serialize(result[:records]),
        count: result[:count]
      }
    else
      postgres_databases = Serializers::Postgres.serialize(project.postgres_resources_dataset.authorized(@user.id, "Postgres:view").eager(:semaphores, :strand, :representative_server, :timeline).all, {include_path: true})
      @app.instance_variable_set(:@postgres_databases, postgres_databases)
      @app.view "postgres/index"
    end
  end

  def post(name: nil)
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?

    Validation.validate_postgres_location(@location)

    required_parameters = ["size"]
    required_parameters << "name" << "location" if @mode == AppMode::WEB
    allowed_optional_parameters = ["storage_size", "ha_type"]
    request_body_params = Validation.validate_request_body(params, required_parameters, allowed_optional_parameters)
    parsed_size = Validation.validate_postgres_size(request_body_params["size"])

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: @location,
      name: name,
      target_vm_size: parsed_size.vm_size,
      target_storage_size_gib: request_body_params["storage_size"] || parsed_size.storage_size_options.first,
      ha_type: request_body_params["ha_type"] || PostgresResource::HaType::NONE
    )

    if @mode == AppMode::API
      Serializers::Postgres.serialize(st.subject, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      @request.redirect "#{project.path}#{PostgresResource[st.id].path}"
    end
  end

  def get
    Authorization.authorize(@user.id, "Postgres:view", @resource.id)
    if @mode == AppMode::API
      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
      @app.instance_variable_set(:@pg, Serializers::Postgres.serialize(@resource, {detailed: true, include_path: true}))
      @app.view "postgres/show"
    end
  end

  def delete
    Authorization.authorize(@user.id, "Postgres:delete", @resource.id)
    @resource.incr_destroy
    if @mode == AppMode::API
      response.status = 204
      @request.halt
    else
      {message: "Deleting #{@resource.name}"}.to_json
    end
  end

  def post_firewall_rule
    Authorization.authorize(@user.id, "Postgres:Firewall:edit", @resource.id)
    if @mode == AppMode::API
      required_parameters = ["cidr"]

      request_body_params = Validation.validate_request_body(@request.body.read, required_parameters)
      Validation.validate_cidr(request_body_params["cidr"])

      DB.transaction do
        PostgresFirewallRule.create_with_id(
          postgres_resource_id: @resource.id,
          cidr: request_body_params["cidr"]
        )
        @resource.incr_update_firewall_rules
      end

      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
      parsed_cidr = Validation.validate_cidr(@request.params["cidr"])

      DB.transaction do
        PostgresFirewallRule.create_with_id(
          postgres_resource_id: @resource.id,
          cidr: parsed_cidr.to_s
        )
        @resource.incr_update_firewall_rules
      end

      flash["notice"] = "Firewall rule is created"
      @request.redirect "#{project.path}#{@resource.path}"
    end
  end

  def get_firewall_rule
    Authorization.authorize(@user.id, "Postgres:Firewall:view", @resource.id)
    Serializers::PostgresFirewallRule.serialize(@resource.firewall_rules)
  end

  def delete_firewall_rule(firewall_rule_ubid)
    Authorization.authorize(@user.id, "Postgres:Firewall:edit", @resource.id)
    fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid)
    if @mode == AppMode::API
      if fwr
        DB.transaction do
          fwr.destroy
          @resource.incr_update_firewall_rules
        end
      end
      response.status = 204
      @request.halt
    else
      unless fwr
        response.status = 404
        @request.halt
      end

      DB.transaction do
        fwr.destroy
        @resource.incr_update_firewall_rules
      end
      {message: "Firewall rule deleted"}.to_json
    end
  end

  def post_metric_destination
    Authorization.authorize(@user.id, "Postgres:edit", @resource.id)
    if @mode == AppMode::API
      required_parameters = ["url", "username", "password"]
      request_body_params = Validation.validate_request_body(@request.body.read, required_parameters)

      Validation.validate_url(request_body_params["url"])

      DB.transaction do
        PostgresMetricDestination.create_with_id(
          postgres_resource_id: @resource.id,
          url: request_body_params["url"],
          username: request_body_params["username"],
          password: request_body_params["password"]
        )
        @resource.servers.each(&:incr_configure_prometheus)
      end

      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
      Validation.validate_url(@request.params["url"])

      DB.transaction do
        PostgresMetricDestination.create_with_id(
          postgres_resource_id: @resource.id,
          url: @request.params["url"],
          username: @request.params["username"],
          password: @request.params["password"]
        )
        @resource.servers.each(&:incr_configure_prometheus)
      end

      flash["notice"] = "Metric destination is created"

      @request.redirect "#{project.path}#{@resource.path}"
    end
  end

  def delete_metric_destination(metric_destination_ubid)
    Authorization.authorize(@user.id, "Postgres:edit", @resource.id)
    md = PostgresMetricDestination.from_ubid(metric_destination_ubid)
    if @mode == AppMode::API
      if md
        DB.transaction do
          md.destroy
          @resource.servers.each(&:incr_configure_prometheus)
        end
      end
    elsif md
      DB.transaction do
        md.destroy
        @resource.servers.each(&:incr_configure_prometheus)
      end

    end
    response.status = 204
    @request.halt
  end

  def restore
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    Authorization.authorize(@user.id, "Postgres:view", @resource.id)
    if @mode == AppMode::API
      required_parameters = ["name", "restore_target"]
      request_body_params = Validation.validate_request_body(@request.body.read, required_parameters)

      st = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location: @resource.location,
        name: request_body_params["name"],
        target_vm_size: @resource.target_vm_size,
        target_storage_size_gib: @resource.target_storage_size_gib,
        parent_id: @resource.id,
        restore_target: request_body_params["restore_target"]
      )

      Serializers::Postgres.serialize(st.subject, {detailed: true})
    else
      st = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location: @resource.location,
        name: @request.params["name"],
        target_vm_size: @resource.target_vm_size,
        target_storage_size_gib: @resource.target_storage_size_gib,
        parent_id: @resource.id,
        restore_target: @request.params["restore_target"]
      )

      flash["notice"] = "'#{@request.params["name"]}' will be ready in a few minutes"

      @request.redirect "#{project.path}#{st.subject.path}"
    end
  end

  def reset_superuser_password
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    Authorization.authorize(@user.id, "Postgres:view", @resource.id)
    if @mode == AppMode::API
      unless @resource.representative_server.primary?
        fail CloverError.new(400, "InvalidRequest", "Superuser password cannot be updated during restore!")
      end

      required_parameters = ["password"]
      request_body_params = Validation.validate_request_body(@request.body.read, required_parameters)
      Validation.validate_postgres_superuser_password(request_body_params["password"])

      DB.transaction do
        @resource.update(superuser_password: request_body_params["password"])
        @resource.representative_server.incr_update_superuser_password
      end

      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
      unless @resource.representative_server.primary?
        flash["error"] = "Superuser password cannot be updated during restore!"
        return @app.redirect_back_with_inputs
      end

      Validation.validate_postgres_superuser_password(@request.params["original_password"], @request.params["repeat_password"])

      @resource.update(superuser_password: @request.params["original_password"])
      @resource.representative_server.incr_update_superuser_password

      flash["notice"] = "The superuser password will be updated in a few seconds"

      @request.redirect "#{project.path}#{@resource.path}"
    end
  end

  def restart
    Authorization.authorize(@user.id, "Postgres:edit", @resource.id)
    @resource.servers.each do |s|
      s.incr_restart
    rescue Sequel::ForeignKeyConstraintViolation
    end
    @request.redirect "#{project.path}#{@resource.path}"
  end

  def view_create_page
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    @app.instance_variable_set(:@prices, @app.fetch_location_based_prices("PostgresCores", "PostgresStorage"))
    @app.instance_variable_set(:@has_valid_payment_method, project.has_valid_payment_method?)
    @app.view "postgres/create"
  end

  def failover
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    Authorization.authorize(@user.id, "Postgres:view", @resource.id)

    unless @resource.representative_server.primary?
      fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered during restore!")
    end

    unless project.get_ff_postgresql_base_image
      fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered for this resource!")
    end

    unless @resource.representative_server.trigger_failover
      fail CloverError.new(400, "InvalidRequest", "There is not a suitable standby server to failover!")
    end

    Serializers::Postgres.serialize(@resource, {detailed: true})
  end
end
