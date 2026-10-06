# frozen_string_literal: true

class Clover
  # Providers with a web implementation: views/networking/private_link_service/<provider>/,
  # a private_link_service_<provider>_post helper and an entry below.
  PRIVATE_LINK_SERVICE_PROVIDERS = %w[aws].freeze

  PRIVATE_LINK_SERVICE_PROVIDER_UI = {
    "aws" => {
      label: "AWS service endpoints",
      blurb: "Expose a PostgreSQL resource to other AWS accounts through AWS PrivateLink.",
      create: "Create AWS service endpoint",
    },
  }.freeze

  def private_link_service_provider_ui(provider)
    PRIVATE_LINK_SERVICE_PROVIDER_UI.fetch(provider)
  end

  # Off unless the installation enables it and the project has the provider's
  # feature flag; every web and API route for the feature checks this.
  def private_link_service_provider_enabled?(provider)
    Config.private_link_service_enabled &&
      PRIVATE_LINK_SERVICE_PROVIDERS.include?(provider) &&
      @project.public_send(:"get_ff_private_link_service_#{provider}") == true
  end

  def private_link_service_enabled_providers
    PRIVATE_LINK_SERVICE_PROVIDERS.select { private_link_service_provider_enabled?(it) }
  end

  def private_link_service_enabled?
    private_link_service_enabled_providers.any?
  end

  def private_link_service_load_options(provider)
    @private_subnets = private_link_service_in_provider(dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view"), :private_subnet, provider).eager(:location).all
    @postgres_resources = private_link_service_in_provider(dataset_authorize(@project.postgres_resources_dataset, "Postgres:edit"), :postgres_resource, provider).without_private_link_service.eager(:location).all
  end

  # table qualifies the columns the join on location would make ambiguous.
  def private_link_service_in_provider(ds, table, provider)
    ds.join(:location, id: Sequel[table][:location_id]).where(Sequel[:location][:provider] => provider).select_all(table)
  end

  def private_link_service_list(provider)
    @provider = provider
    @private_link_services = private_link_service_in_provider(dataset_authorize(@project.private_link_services_dataset, "PrivateLinkService:view"), :private_link_service, provider)
      .eager(:location, :private_subnet, :postgres_resource, :strand, :semaphores, :private_link_service_aws_resource)
      .order(Sequel[:private_link_service][:name])
      .all
    view "networking/private_link_service/index"
  end

  def private_link_service_api_list
    ds = dataset_authorize(@project.private_link_services_dataset, "PrivateLinkService:view")
      .eager(:location, :private_subnet, :postgres_resource, :ports, :strand, :semaphores, :private_link_service_aws_resource)
    ds = ds.where(location_id: @location.id) if @location
    paginated_result(ds, Serializers::PrivateLinkService)
  end

  def private_link_service_aws_post
    # Authorize before reading params: a malformed id raises in typecasting,
    # and every non-GET request must have made an authorization check by then.
    authorize("PrivateLinkService:create", @project)
    ps = private_link_service_subnet_param
    name = typecast_params.nonempty_str!("name")
    allowed_principals = private_link_service_principals_param
    aws_supported_regions = private_link_service_supported_regions_param(ps, typecast_params.array(:nonempty_str, "aws_supported_regions"))
    private_link_service_create(name, ps, private_link_service_postgres_param(ps), allowed_principals:, ip_address_type: private_link_service_ip_address_type_param, aws_supported_regions:, aws_allowed_vpc_endpoints: [])
  end

  def private_link_service_api_post(name)
    authorize("PrivateLinkService:create", @project)
    ps = private_link_service_subnet_param(location_id: @location.id)
    private_link_service_api_create(name, ps, private_link_service_postgres_param(ps))
  end

  def private_link_service_api_create(name, ps, pg)
    aws = typecast_params["aws"]
    allowed_principals = private_link_service_clean_principals(aws.array!(:nonempty_str, "allowed_principals"))
    aws_supported_regions = private_link_service_supported_regions_param(ps, aws.array(:nonempty_str, "supported_regions"), key: "supported_regions")
    aws_allowed_vpc_endpoints = private_link_service_clean_vpc_endpoints(aws.array(:Hash, "allowed_vpc_endpoints", []).map { [it["vpc_endpoint_id"], it["description"]] })
    private_link_service_create(name, ps, pg, allowed_principals:, ip_address_type: private_link_service_ip_address_type_param, aws_supported_regions:, aws_allowed_vpc_endpoints:)
  end

  # Provider-neutral, so top level in both the form and the API body.
  def private_link_service_ip_address_type_param
    type = typecast_params.nonempty_str("ip_address_type") || "ipv4"
    unless PRIVATE_LINK_SERVICE_IP_ADDRESS_TYPE_LABELS.key?(type)
      fail Validation::ValidationFailed.new("ip_address_type" => "Must be one of: #{PRIVATE_LINK_SERVICE_IP_ADDRESS_TYPE_LABELS.keys.join(", ")}")
    end
    type
  end

  # Creating needs sight of the subnet, not the right to edit it.
  def private_link_service_subnet_param(location_id: nil)
    ps = authorized_private_subnet(location_id:)
    unless ps&.location&.aws?
      fail Validation::ValidationFailed.new("private_subnet_id" => "Private subnet not found in an AWS location")
    end
    ps
  end

  def private_link_service_postgres_param(ps)
    return unless (postgres_resource_id = typecast_params.ubid_uuid("postgres_resource_id"))

    pg = authorized_object(association: :postgres_resources, key: "postgres_resource_id", perm: "Postgres:edit", id: postgres_resource_id)
    unless pg && pg.private_subnet_id == ps.id
      fail Validation::ValidationFailed.new("postgres_resource_id" => "PostgreSQL resource not found in the selected private subnet")
    end
    pg
  end

  # The caller has authorized PrivateLinkService:create.
  def private_link_service_create(name, ps, pg, allowed_principals:, ip_address_type:, aws_supported_regions:, aws_allowed_vpc_endpoints:)
    ports = private_link_service_ports_param

    if @project.private_link_services_dataset.where(location_id: ps.location_id, name:).any?
      fail Validation::ValidationFailed.new("name" => "A private link service named '#{name}' already exists in location '#{ps.display_location}'")
    end
    if pg&.private_link_service
      fail Validation::ValidationFailed.new("postgres_resource_id" => "PostgreSQL resource already has a private link service")
    end

    pls = DB.transaction do
      strand = Prog::Vnet::PrivateLinkServiceNexus.assemble(
        project_id: @project.id,
        private_subnet_id: ps.id,
        name:,
        allowed_principals:,
        postgres_resource_id: pg&.id,
        ports:,
        ip_address_type:,
        aws_supported_regions:,
        aws_allowed_vpc_endpoints:,
      )
      audit_log(strand.subject, "create")
      strand.subject
    end

    if api?
      Serializers::PrivateLinkService.serialize(pls, {detailed: true})
    else
      flash["notice"] = "'#{name}' is being created"
      request.redirect pls
    end
  end

  # Fields left out of body.aws are unchanged.
  def private_link_service_api_patch(pls)
    authorize("PrivateLinkService:edit", pls)
    principals = regions = endpoints = nil
    if typecast_params.present?("aws")
      section = typecast_params["aws"]
      principals = private_link_service_clean_principals(section.array!(:nonempty_str, "allowed_principals")) if section.present?("allowed_principals")
      endpoints = (list = section.array(:Hash, "allowed_vpc_endpoints")) && private_link_service_clean_vpc_endpoints(list.map { [it["vpc_endpoint_id"], it["description"]] })
      regions = (list = section.array(:nonempty_str, "supported_regions")) && private_link_service_supported_regions_param(pls.private_subnet, list, key: "supported_regions")
    end

    if principals || endpoints || regions
      DB.transaction do
        pls.update_allowed_principals(principals) if principals
        pls.private_link_service_aws_resource.update_allowed_endpoints(endpoints) if endpoints
        pls.private_link_service_aws_resource.update_supported_regions(regions) if regions
        audit_log(pls, "update")
      end
    else
      no_audit_log
    end

    Serializers::PrivateLinkService.serialize(pls.reload, {detailed: true})
  end

  def private_link_service_principals_param
    private_link_service_clean_principals(typecast_params.array!(:nonempty_str, "allowed_principals"))
  end

  def private_link_service_clean_principals(principals)
    principals = principals.map(&:strip).uniq
    Validation.validate_aws_principals(principals)
    principals
  end

  # Blank form rows are placeholders and are dropped.
  def private_link_service_clean_vpc_endpoints(entries)
    entries = entries.map { |id, description| [id.to_s.strip, description.to_s.strip] }.reject { |id, _| id.empty? }
    Validation.validate_aws_vpc_endpoints(entries)
    entries
  end

  def private_link_service_vpc_endpoints_form_param
    ids = typecast_params.array(:str, "allowed_vpc_endpoint_ids") || []
    descriptions = typecast_params.array(:str, "allowed_vpc_endpoint_descriptions") || []
    private_link_service_clean_vpc_endpoints(ids.zip(descriptions))
  end

  # An opt-in region the provider account has not enabled is refused here,
  # since AWS would refuse it at reconcile. key is the form field or, for the
  # API, the body field.
  def private_link_service_supported_regions_param(ps, regions, key: "aws_supported_regions")
    # Placeholder form rows post "", which nonempty_str turns into nil; drop them.
    regions = (regions || []).compact.uniq
    unless (regions - PrivateLinkServiceAwsResource.supported_regions).empty?
      fail Validation::ValidationFailed.new(key => "Unknown AWS region selected")
    end
    regions = (regions - [ps.location.name]).sort
    return regions if regions.empty?

    enabled = begin
      ps.location.location_credential_aws.enabled_regions
    rescue Aws::EC2::Errors::ServiceError, Seahorse::Client::NetworkingError
      fail Validation::ValidationFailed.new(key => "Could not check the regions enabled in the provider's AWS account, try again")
    end
    disabled = regions - enabled
    unless disabled.empty?
      fail Validation::ValidationFailed.new(key => "Not enabled in the provider's AWS account: #{disabled.join(", ")}")
    end

    regions
  end

  PRIVATE_LINK_SERVICE_IP_ADDRESS_TYPE_LABELS = {
    "ipv4" => "IPv4",
    "ipv6" => "IPv6",
    "dual" => "Dual stack",
  }.freeze

  PRIVATE_LINK_SERVICE_DNS_STATE_LABELS = {
    "verified" => ["Verified", "bg-green-100 text-green-800"],
    "pendingVerification" => ["Pending verification", "bg-yellow-100 text-yellow-800"],
    "failed" => ["Verification failed", "bg-red-100 text-red-800"],
  }.freeze

  def private_link_service_dns_state_label(state)
    PRIVATE_LINK_SERVICE_DNS_STATE_LABELS.fetch(state, ["Not verified yet", "bg-slate-100 text-slate-800"])
  end

  # ports[] and target_ports[] are parallel; the PostgreSQL defaults apply
  # when the request does not mention ports.
  def private_link_service_ports_param
    ports = typecast_params.array(:pos_int, "ports")
    return Prog::Vnet::PrivateLinkServiceNexus::DEFAULT_POSTGRES_PORTS if ports.nil?

    target_ports = typecast_params.array(:pos_int, "target_ports") || []
    if ports.empty? || ports.length != target_ports.length
      fail Validation::ValidationFailed.new("ports" => "Each port needs a target port and at least one port is required")
    end
    # pos_int leaves nil for zero, negative or blank entries.
    unless (ports + target_ports).all? { it && it <= 65535 }
      fail Validation::ValidationFailed.new("ports" => "Ports must be between 1 and 65535")
    end
    unless ports.uniq.length == ports.length
      fail Validation::ValidationFailed.new("ports" => "Ports must be unique")
    end

    ports.zip(target_ports)
  end

  def private_link_service_attachable_postgres_resources(pls)
    dataset_authorize(@project.postgres_resources_dataset, "Postgres:edit")
      .where(private_subnet_id: pls.private_subnet_id)
      .without_private_link_service
      .order(:name)
      .all
  end
end
