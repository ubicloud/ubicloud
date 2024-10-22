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
    allowed_optional_parameters = ["storage_size", "ha_type", "version", "flavor"]
    request_body_params = Validation.validate_request_body(params, required_parameters, allowed_optional_parameters)
    parsed_size = Validation.validate_postgres_size(@location, request_body_params["size"])

    ha_type = request_body_params["ha_type"] || PostgresResource::HaType::NONE
    requested_standby_count = case ha_type
    when PostgresResource::HaType::ASYNC then 1
    when PostgresResource::HaType::SYNC then 2
    else 0
    end

    requested_postgres_core_count = (requested_standby_count + 1) * parsed_size.vcpu / 2
    Validation.validate_core_quota(project, "PostgresCores", requested_postgres_core_count)

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: @location,
      name: name,
      target_vm_size: parsed_size.vm_size,
      target_storage_size_gib: request_body_params["storage_size"] || parsed_size.storage_size_options.first,
      ha_type: request_body_params["ha_type"] || PostgresResource::HaType::NONE,
      version: request_body_params["version"] || PostgresResource::DEFAULT_VERSION,
      flavor: request_body_params["flavor"] || PostgresResource::Flavor::STANDARD
    )
    send_notification_mail_to_partners(st.subject, @user.email)

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
    response.status = 204
    @request.halt
  end

  def post_firewall_rule
    Authorization.authorize(@user.id, "Postgres:Firewall:edit", @resource.id)

    required_parameters = ["cidr"]
    request_body_params = Validation.validate_request_body(params, required_parameters)
    parsed_cidr = Validation.validate_cidr(request_body_params["cidr"])

    DB.transaction do
      PostgresFirewallRule.create_with_id(
        postgres_resource_id: @resource.id,
        cidr: parsed_cidr.to_s
      )
      @resource.incr_update_firewall_rules
    end

    if @mode == AppMode::API
      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
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

    if (fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid))
      DB.transaction do
        fwr.destroy
        @resource.incr_update_firewall_rules
      end
    end
    response.status = 204
    @request.halt
  end

  def post_metric_destination
    Authorization.authorize(@user.id, "Postgres:edit", @resource.id)

    required_parameters = ["url", "username", "password"]
    request_body_params = Validation.validate_request_body(params, required_parameters)

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

    if @mode == AppMode::API
      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
      flash["notice"] = "Metric destination is created"
      @request.redirect "#{project.path}#{@resource.path}"
    end
  end

  def delete_metric_destination(metric_destination_ubid)
    Authorization.authorize(@user.id, "Postgres:edit", @resource.id)

    if (md = PostgresMetricDestination.from_ubid(metric_destination_ubid))
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

    required_parameters = ["name", "restore_target"]
    request_body_params = Validation.validate_request_body(params, required_parameters)

    st = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: @resource.location,
      name: request_body_params["name"],
      target_vm_size: @resource.target_vm_size,
      target_storage_size_gib: @resource.target_storage_size_gib,
      version: @resource.version,
      flavor: @resource.flavor,
      parent_id: @resource.id,
      restore_target: request_body_params["restore_target"]
    )
    send_notification_mail_to_partners(st.subject, @user.email)

    if @mode == AppMode::API
      Serializers::Postgres.serialize(st.subject, {detailed: true})
    else
      flash["notice"] = "'#{request_body_params["name"]}' will be ready in a few minutes"
      @request.redirect "#{project.path}#{st.subject.path}"
    end
  end

  def reset_superuser_password
    Authorization.authorize(@user.id, "Postgres:create", project.id)
    Authorization.authorize(@user.id, "Postgres:view", @resource.id)

    unless @resource.representative_server.primary?
      if @mode == AppMode::API
        fail CloverError.new(400, "InvalidRequest", "Superuser password cannot be updated during restore!")
      else
        flash["error"] = "Superuser password cannot be updated during restore!"
        return @app.redirect_back_with_inputs
      end
    end

    required_parameters = (@mode == AppMode::API) ? ["password"] : ["password", "repeat_password"]
    request_body_params = Validation.validate_request_body(params, required_parameters)
    Validation.validate_postgres_superuser_password(request_body_params["password"], request_body_params["repeat_password"])

    DB.transaction do
      @resource.update(superuser_password: request_body_params["password"])
      @resource.representative_server.incr_update_superuser_password
    end

    if @mode == AppMode::API
      Serializers::Postgres.serialize(@resource, {detailed: true})
    else
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
    flavor = @request.params["flavor"] || PostgresResource::Flavor::STANDARD
    Validation.validate_postgres_flavor(flavor)
    @app.instance_variable_set(:@flavor, flavor)
    @app.instance_variable_set(:@prices, @app.fetch_location_based_prices("PostgresCores", "PostgresStorage"))
    @app.instance_variable_set(:@has_valid_payment_method, project.has_valid_payment_method?)
    @app.instance_variable_set(:@enabled_postgres_sizes, Option::VmSizes.select { project.quota_available?("PostgresCores", _1.vcpu / 2) }.map(&:name))
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

  def send_notification_mail_to_partners(resource, user_email)
    if [PostgresResource::Flavor::PARADEDB, PostgresResource::Flavor::LANTERN].include?(resource.flavor) && (email = Config.send(:"postgres_#{resource.flavor}_notification_email"))
      flavor_name = resource.flavor.capitalize
      Util.send_email(email, "New #{flavor_name} Postgres database has been created.",
        greeting: "Hello #{flavor_name} team,",
        body: ["New #{flavor_name} Postgres database has been created.",
          "ID: #{resource.ubid}",
          "Location: #{resource.location}",
          "Name: #{resource.name}",
          "E-mail: #{user_email}",
          "Instance VM Size: #{resource.target_vm_size}",
          "Instance Storage Size: #{resource.target_storage_size_gib}",
          "HA: #{resource.ha_type}"])
    end
  end
end
