# frozen_string_literal: true

class Clover
  def postgres_post(name)
    authorize("Postgres:create", @project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    flavor = typecast_params.nonempty_str("flavor", PostgresResource::Flavor::STANDARD)
    size = typecast_params.nonempty_str!("size")
    storage_size = typecast_params.pos_int("storage_size")
    ha_type = typecast_params.nonempty_str("ha_type", PostgresResource::HaType::NONE)
    version = typecast_params.nonempty_str("version", PostgresResource::DEFAULT_VERSION)

    postgres_params = {
      "flavor" => flavor,
      "location" => @location,
      "family" => Option::POSTGRES_SIZE_OPTIONS[size]&.family,
      "size" => size,
      "storage_size" => storage_size.to_s,
      "ha_type" => ha_type,
      "version" => version
    }

    validate_postgres_input(name, postgres_params)

    parsed_size = Option::POSTGRES_SIZE_OPTIONS[postgres_params["size"]]
    requested_standby_count = Option::POSTGRES_HA_OPTIONS[postgres_params["ha_type"]].standby_count
    requested_postgres_vcpu_count = (requested_standby_count + 1) * parsed_size.vcpu_count
    Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count)

    pg = nil
    DB.transaction do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: @location.id,
        name:,
        target_vm_size: parsed_size.name,
        target_storage_size_gib: storage_size,
        ha_type:,
        version:,
        flavor:
      ).subject
      audit_log(pg, "create")
    end
    send_notification_mail_to_partners(pg, current_account.email)

    if api?
      Serializers::Postgres.serialize(pg, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{@project.path}#{pg.path}/overview"
    end
  end

  def postgres_list
    dataset = dataset_authorize(@project.postgres_resources_dataset.eager, "Postgres:view").eager(:semaphores, :location, strand: :children)
    if api?
      dataset = dataset.where(location_id: @location.id) if @location
      paginated_result(dataset, Serializers::Postgres)
    else
      dataset = dataset.eager(:representative_server, :timeline)
      resources = dataset.all
        .group_by { |r| r.read_replica? ? r[:parent_id] : r[:id] }
        .flat_map { |group_id, rs| rs.sort_by { |r| r[:created_at] } }

      @postgres_databases = Serializers::Postgres.serialize(resources, {include_path: true})
      view "postgres/index"
    end
  end

  def send_notification_mail_to_partners(resource, user_email)
    if [PostgresResource::Flavor::PARADEDB, PostgresResource::Flavor::LANTERN].include?(resource.flavor) && (email = Config.send(:"postgres_#{resource.flavor}_notification_email"))
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

  def generate_postgres_options(flavor: nil, location: nil)
    options = OptionTreeGenerator.new

    options.add_option(name: "name")

    options.add_option(name: "flavor", values: flavor || postgres_flavors.keys)

    options.add_option(name: "location", values: location || postgres_locations, parent: "flavor") do |flavor, location|
      flavor == PostgresResource::Flavor::STANDARD || location.provider != "aws"
    end

    options.add_option(name: "family", values: Option::POSTGRES_FAMILY_OPTIONS.keys, parent: "location") do |flavor, location, family|
      if location.aws?
        family == "m6id" || (Option::AWS_FAMILY_OPTIONS.include?(family) && @project.send(:"get_ff_enable_#{family}"))
      else
        family == "standard" || family == "burstable"
      end
    end

    options.add_option(name: "size", values: Option::POSTGRES_SIZE_OPTIONS.keys, parent: "family") do |flavor, location, family, size|
      Option::POSTGRES_SIZE_OPTIONS[size].family == family
    end

    storage_size_options = Option::POSTGRES_STORAGE_SIZE_OPTIONS + Option::AWS_STORAGE_SIZE_OPTIONS.values.flatten.uniq
    options.add_option(name: "storage_size", values: storage_size_options, parent: "size") do |flavor, location, family, size, storage_size|
      vcpu_count = Option::POSTGRES_SIZE_OPTIONS[size].vcpu_count

      if location.aws?
        Option::AWS_STORAGE_SIZE_OPTIONS[vcpu_count].include?(storage_size)
      else
        min_storage = (vcpu_count >= 30) ? 1024 : vcpu_count * 32
        min_storage /= 2 if family == "burstable"
        [min_storage, min_storage * 2, min_storage * 4].include?(storage_size.to_i)
      end
    end

    options.add_option(name: "version", values: Option::POSTGRES_VERSION_OPTIONS)

    options.add_option(name: "ha_type", values: Option::POSTGRES_HA_OPTIONS.keys, parent: "storage_size")

    options.serialize
  end

  def postgres_flavors
    Option::POSTGRES_FLAVOR_OPTIONS.reject { |k, _| k == PostgresResource::Flavor::LANTERN && !@project.get_ff_postgres_lantern }
  end

  def postgres_locations
    Location.where(name: ["hetzner-fsn1", "leaseweb-wdc02"]).all + @project.locations
  end

  def validate_postgres_input(name, postgres_params)
    Validation.validate_name(name)

    option_tree, option_parents = generate_postgres_options

    begin
      Validation.validate_from_option_tree(option_tree, option_parents, postgres_params)
    rescue Validation::ValidationFailed => e
      fail Validation::ValidationFailed.new({size: "Invalid size."}) if e.details.key?(:family)
      raise e
    end
  end
end
