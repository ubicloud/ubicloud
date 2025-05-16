# frozen_string_literal: true

class Clover
  def postgres_post(name)
    authorize("Postgres:create", @project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    Validation.validate_postgres_location(@location, @project.id)

    size = typecast_params.nonempty_str!("size")
    parsed_size = Validation.validate_postgres_size(@location, size, @project.id)

    ha_type = typecast_params.nonempty_str("ha_type") || PostgresResource::HaType::NONE
    requested_standby_count = case ha_type
    when PostgresResource::HaType::ASYNC then 1
    when PostgresResource::HaType::SYNC then 2
    else 0
    end

    requested_postgres_vcpu_count = (requested_standby_count + 1) * parsed_size.vcpu
    Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count)

    pg = nil
    DB.transaction do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: @location.id,
        name:,
        target_vm_size: parsed_size.vm_size,
        target_storage_size_gib: typecast_params.nonempty_str("storage_size") || parsed_size.storage_size_options.first,
        ha_type:,
        version: typecast_params.nonempty_str("version") || PostgresResource::DEFAULT_VERSION,
        flavor: typecast_params.nonempty_str("flavor") || PostgresResource::Flavor::STANDARD
      ).subject
      audit_log(pg, "create")
    end
    send_notification_mail_to_partners(pg, current_account.email)

    if api?
      Serializers::Postgres.serialize(pg, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{@project.path}#{pg.path}"
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

  def generate_postgres_options(flavor: "standard")
    options = OptionTreeGenerator.new
    all_sizes_for_project = Option.customer_postgres_sizes_for_project(@project.id)

    options.add_option(name: "name")
    options.add_option(name: "flavor", values: flavor)
    options.add_option(name: "location", values: Option.postgres_locations(project_id: @project.id), parent: "flavor") do |flavor, location|
      !(location.provider == "aws" && flavor != PostgresResource::Flavor::STANDARD)
    end
    options.add_option(name: "family", values: all_sizes_for_project.map(&:vm_family).uniq, parent: "location") do |flavor, location, family|
      if location.provider == "aws" && family != "standard"
        false
      else
        available_families = Option.families.map(&:name)
        available_families.include?(family) && BillingRate.from_resource_properties("PostgresVCpu", "#{flavor}-#{family}", location.name)
      end
    end
    options.add_option(name: "size", values: all_sizes_for_project.map(&:name).uniq, parent: "family") do |flavor, location, family, size|
      if location.provider == "aws" && (size.split("-").last.to_i > 16 || size.split("-").first == "burstable")
        false
      else
        pg_size = all_sizes_for_project.find { it.name == size && it.flavor == flavor && it.location_id == location.id }
        vm_size = Option::VmSizes.find { it.name == pg_size.vm_size && it.arch == "x64" && it.visible }
        vm_size.family == family
      end
    end

    options.add_option(name: "storage_size", values: ["16", "32", "64", "128", "256", "512", "1024", "2048", "4096", "118", "237", "475", "950", "1781", "1900", "3562", "3800"], parent: "size") do |flavor, location, family, size, storage_size|
      pg_size = all_sizes_for_project.find { it.name == size && it.flavor == flavor && it.location_id == location.id }
      pg_size.storage_size_options.include?(storage_size.to_i)
    end

    options.add_option(name: "version", values: Option::POSTGRES_VERSION_OPTIONS[flavor], parent: "flavor")

    options.add_option(name: "ha_type", values: [PostgresResource::HaType::NONE, PostgresResource::HaType::ASYNC, PostgresResource::HaType::SYNC], parent: "storage_size")
    options.serialize
  end

  def generate_postgres_configure_options(flavor:, location:)
    options = OptionTreeGenerator.new
    all_sizes_for_project = Option.customer_postgres_sizes_for_project(@project.id)

    options.add_option(name: "flavor", values: flavor)
    options.add_option(name: "location", values: location, parent: "flavor")

    options.add_option(name: "family", values: all_sizes_for_project.map(&:vm_family).uniq, parent: "location") do |flavor, location, family|
      if location.provider == "aws" && family != "standard"
        false
      else
        available_families = Option.families.map(&:name)
        available_families.include?(family) && BillingRate.from_resource_properties("PostgresVCpu", "#{flavor}-#{family}", location.name)
      end
    end

    options.add_option(name: "size", values: all_sizes_for_project.map(&:name).uniq, parent: "family") do |flavor, location, family, size|
      if location.provider == "aws" && (size.split("-").last.to_i > 16 || size.split("-").first == "burstable")
        false
      else
        pg_size = all_sizes_for_project.find { it.name == size && it.flavor == flavor && it.location_id == location.id }
        vm_size = Option::VmSizes.find { it.name == pg_size.vm_size && it.arch == "x64" && it.visible }
        vm_size.family == family
      end
    end

    options.add_option(name: "storage_size", values: ["16", "32", "64", "128", "256", "512", "1024", "2048", "4096", "118", "237", "475", "950", "1781", "1900", "3562", "3800"], parent: "size") do |flavor, location, family, size, storage_size|
      pg_size = all_sizes_for_project.find { it.name == size && it.flavor == flavor && it.location_id == location.id }
      pg_size.storage_size_options.include?(storage_size.to_i)
    end

    options.add_option(name: "ha_type", values: [PostgresResource::HaType::NONE, PostgresResource::HaType::ASYNC, PostgresResource::HaType::SYNC], parent: "storage_size")

    options.serialize
  end
end
