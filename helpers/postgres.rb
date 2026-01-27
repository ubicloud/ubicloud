# frozen_string_literal: true

class Clover
  def postgres_post(name)
    authorize("Postgres:create", @project)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    flavor = typecast_params.nonempty_str("flavor", PostgresResource.default_flavor)
    size = typecast_params.nonempty_str!("size").gsub("burstable", "hobby")
    storage_size = typecast_params.pos_int("storage_size")
    ha_type = typecast_params.nonempty_str("ha_type", PostgresResource.ha_type_none)
    version = typecast_params.nonempty_str("version", PostgresResource.default_version)
    user_config = typecast_params.Hash("pg_config", {})
    pgbouncer_user_config = typecast_params.Hash("pgbouncer_config", {})
    tags = typecast_params.array(:Hash, "tags", [])
    with_firewall_rules = !typecast_params.bool("restrict_by_default")
    private_subnet_name = typecast_params.nonempty_str("private_subnet_name") if api?
    init_script = typecast_params.nonempty_str("init_script")

    postgres_params = {
      "flavor" => flavor,
      "location" => @location,
      "family" => Option::POSTGRES_SIZE_OPTIONS[size]&.family,
      "size" => size,
      "storage_size" => storage_size,
      "ha_type" => ha_type,
      "version" => version
    }

    validate_postgres_input(name, postgres_params)

    parsed_size = Option::POSTGRES_SIZE_OPTIONS[postgres_params["size"]]
    requested_standby_count = Option::POSTGRES_HA_OPTIONS[postgres_params["ha_type"]].standby_count
    requested_postgres_vcpu_count = (requested_standby_count + 1) * parsed_size.vcpu_count
    Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count)

    validate_postgres_config(version, user_config, pgbouncer_user_config)

    pg = nil
    DB.transaction do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: @location.id,
        name:,
        target_vm_size: parsed_size.name,
        target_storage_size_gib: storage_size,
        target_version: version,
        ha_type:,
        with_firewall_rules:,
        flavor:,
        private_subnet_name:,
        user_config:,
        pgbouncer_user_config:,
        tags:,
        init_script:
      ).subject
      audit_log(pg, "create")
    end
    send_notification_mail_to_partners(pg, current_account.email)

    if api?
      Serializers::Postgres.serialize(pg, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect pg, "/overview"
    end
  end

  def postgres_list(tags_param: nil)
    dataset = dataset_authorize(@project.postgres_resources_dataset.eager(:timeline, representative_server: [:strand, vm: :vm_storage_volumes]), "Postgres:view").eager(:semaphores, :location, strand: :children)

    @tags_filter = tags_param

    if tags_param
      tags_param = tags_param.split(",")
      tags_param = tags_param.map! { |tag| tag.split(":", 2).map(&:strip) }
      tags_param = tags_param.map! { |key, value| {key:, value:} }
      tags_param.each do |tag|
        unless tag[:value]
          fail Validation::ValidationFailed.new({tags: "Invalid tag format. Expected format: key:value"})
        end
      end
      dataset = dataset.where(Sequel.pg_jsonb_op(:tags).contains(tags_param))
    end

    if api?
      dataset = dataset.where(location_id: @location.id) if @location
      paginated_result(dataset, Serializers::Postgres)
    else
      @postgres_databases = dataset.all
        .group_by { |r| r.read_replica? ? r[:parent_id] : r[:id] }
        .flat_map { |group_id, rs| rs.sort_by { |r| r[:created_at] } }
      view "postgres/index"
    end
  end

  def send_notification_mail_to_partners(resource, user_email)
    if resource.requires_partner_notification_email? && (email = Config.send(:"postgres_#{resource.flavor}_notification_email"))
      flavor_name = resource.flavor.capitalize
      Util.send_email(email, "New #{flavor_name} Postgres database has been created.",
        greeting: "Hello #{flavor_name} team,",
        body: ["New #{flavor_name} Postgres database has been created.",
          "ID: #{resource.ubid}",
          "Location: #{resource.location.display_name}",
          "Name: #{resource.name}",
          "E-mail: #{user_email}",
          "Instance VM Size: #{resource.target_vm_size}",
          "Instance Storage Size: #{resource.target_storage_size_gib}",
          "HA: #{resource.ha_type}"])
    end
  end

  def postgres_require_customer_firewall!
    unless (fw = @pg.customer_firewall)
      raise CloverError.new(400, "InvalidRequest", "PostgreSQL firewall was deleted, manage firewall rules using an appropriate firewall on the #{@pg.private_subnet.name} private subnet (id: #{@pg.private_subnet.ubid})")
    end

    fw
  end

  def validate_postgres_config(version, user_config, pgbouncer_user_config)
    pg_validator = Validation::PostgresConfigValidator.new(version)
    pg_errors = pg_validator.validation_errors(user_config)

    pgbouncer_validator = Validation::PostgresConfigValidator.new("pgbouncer")
    pgbouncer_errors = pgbouncer_validator.validation_errors(pgbouncer_user_config)

    if pg_errors.any? || pgbouncer_errors.any?
      pg_errors = pg_errors.transform_keys { |key| "pg_config.#{key}" }
      pgbouncer_errors = pgbouncer_errors.transform_keys { |key| "pgbouncer_config.#{key}" }
      raise Validation::ValidationFailed.new(pg_errors.merge(pgbouncer_errors))
    end
  end

  def validate_postgres_input(name, postgres_params)
    Validation.validate_name(name)

    option_tree, option_parents = PostgresResource.generate_postgres_options(@project)

    begin
      Validation.validate_from_option_tree(option_tree, option_parents, postgres_params)
    rescue Validation::ValidationFailed => e
      fail Validation::ValidationFailed.new({size: "Invalid size."}) if e.details.key?(:family)

      raise e
    end

    Validation.validate_postgres_version(postgres_params["version"], postgres_params["flavor"])
  end
end
