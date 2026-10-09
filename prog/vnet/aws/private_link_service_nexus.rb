# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-elasticloadbalancingv2"

# Every ensure_* step is idempotent: the whole chain re-runs on the reconcile
# semaphore, and the teardown chain runs in reverse order from destroy.
class Prog::Vnet::Aws::PrivateLinkServiceNexus < Prog::Base
  subject_is :private_link_service, :private_link_service_aws_resource

  PRIVATE_DNS_RECORD_TTL = 60

  # The zone nexus pushes a new record to the Knot VMs within about 10 s of
  # the insert; AWS is asked to look it up only once the record is older.
  PRIVATE_DNS_RECORD_SETTLE_SECONDS = 60

  # Supported-region states under which consumers cannot connect from that
  # region; Pending and Available are the live ones.
  INACTIVE_REGION_STATES = %w[Closed Deleting Deleted Failed].freeze

  # Semaphores wake the strand at once; the nap only paces the private DNS
  # check while a name is unverified.
  IDLE_NAP = 5 * 60 * 60

  # Labels run from wait that keep the service available, and the teardown
  # chain entered from destroy; PrivateLinkService#display_state reads both.
  BACKGROUND_LABELS = %w[wait reconcile_connections verify_private_dns update_permissions].freeze
  DESTROY_LABELS = %w[destroy recover_unrecorded_ids delete_endpoint_service wait_service_gone delete_listeners delete_target_groups delete_nlb wait_nlb_gone wait_ports_gone].freeze

  def aws_resource
    private_link_service_aws_resource
  end

  def port_aws(port)
    port.private_link_service_port_aws_resource
  end

  def elbv2_client
    @elbv2_client ||= private_link_service.location.location_credential_aws.elbv2_client
  end

  def ec2_client
    @ec2_client ||= private_link_service.location.location_credential_aws.client
  end

  def vpc_id
    private_link_service.private_subnet.private_subnet_aws_resource.vpc_id
  end

  def nlb_arn
    aws_resource.nlb_arn
  end

  def service_id
    aws_resource.service_id
  end

  label def start
    register_deadline("wait", 15 * 60)
    nap 10 unless private_link_service.private_subnet.strand.label == "wait"
    hop_ensure_target_groups
  end

  # Attributes are set in their own label so a refused call cannot roll back
  # the ARNs recorded here.
  label def ensure_target_groups
    private_link_service.ports.each { ensure_target_group(it) }
    hop_ensure_target_group_attributes
  end

  label def ensure_target_group_attributes
    private_link_service.ports.each do
      arn = port_aws(it).target_group_arn
      current = elbv2_client.describe_target_group_attributes(target_group_arn: arn).attributes
      missing = missing_nlb_attributes(current, TARGET_GROUP_ATTRIBUTES)
      elbv2_client.modify_target_group_attributes(target_group_arn: arn, attributes: missing) unless missing.empty?
    end
    hop_ensure_targets
  end

  # The primary's address in the target groups' family; empty without an
  # attached resource or while the VM has no address yet.
  def desired_target_ips
    private_link_service.target_vms.filter_map { private_link_service.target_ip(it)&.to_s }.uniq.sort
  end

  # An attached resource whose primary has no address yet is waited for: the
  # IPv6 lands only once the instance runs, later than the private IPv4.
  label def ensure_targets
    desired_ips = desired_target_ips
    if desired_ips.empty? && private_link_service.postgres_resource
      Clog.emit("private link service waiting for the primary's address", private_link_service)
      nap 10
    end

    private_link_service.ports.each { ensure_targets_for(it, desired_ips) }
    aws_resource.update(registered_target_ips: Sequel.pg_array(desired_ips, :inet))
    hop_ensure_nlb
  end

  # NLB subnets can be added but never removed; security groups only at creation.
  label def ensure_nlb
    unless nlb_arn
      subnet_ids = aws_subnet_ids
      if subnet_ids.empty?
        Clog.emit("private link service waiting for the private subnet's AWS subnets", private_link_service)
        nap 10
      end

      name = nlb_name
      security_group_ids = nlb_security_group_ids
      params = {
        name:,
        type: "network",
        scheme: "internal",
        ip_address_type: (private_link_service.ip_address_type == "ipv4") ? "ipv4" : "dualstack",
        subnets: subnet_ids,
        tags: Util.aws_tags(name, {"ubid" => private_link_service.ubid}),
      }
      params[:security_groups] = security_group_ids unless security_group_ids.empty?
      arn = begin
        elbv2_client.create_load_balancer(**params).load_balancers.first.load_balancer_arn
      rescue Aws::ElasticLoadBalancingV2::Errors::DuplicateLoadBalancerName
        elbv2_client.describe_load_balancers(names: [name]).load_balancers.first.load_balancer_arn
      end

      aws_resource.update(nlb_arn: arn)
    end

    hop_ensure_nlb_attributes
  end

  # Cross-zone stays on so clients reach the primary whichever AZ it lands in.
  label def ensure_nlb_attributes
    current = elbv2_client.describe_load_balancer_attributes(load_balancer_arn: nlb_arn).attributes
    missing = missing_nlb_attributes(current, NLB_ATTRIBUTES)
    elbv2_client.modify_load_balancer_attributes(load_balancer_arn: nlb_arn, attributes: missing) unless missing.empty?
    hop_wait_nlb_active
  end

  # active_impaired still serves; failed never recovers on its own, so it
  # pages with the reason AWS gives.
  label def wait_nlb_active
    state = elbv2_client.describe_load_balancers(load_balancer_arns: [nlb_arn]).load_balancers.first.state
    case state.code
    when "active", "active_impaired"
      Clog.emit("private link service NLB active but impaired", {private_link_service_nlb_impaired: {ubid: private_link_service.ubid, arn: nlb_arn, reason: state.reason}}) if state.code == "active_impaired"
      nlb_failed_page&.incr_resolve
      hop_ensure_listeners
    when "failed"
      Prog::PageNexus.assemble(
        "Private link service #{private_link_service.ubid} NLB failed to provision: #{state.reason}",
        ["PrivateLinkServiceNlbFailed", private_link_service.id], [private_link_service.ubid],
        resource_id: private_link_service.id, extra_data: {"arn" => nlb_arn, "reason" => state.reason},
      )
      nap 60
    when "provisioning"
      nap 10
    else
      Clog.emit("private link service NLB in unknown state", {private_link_service_nlb_state: {ubid: private_link_service.ubid, state: state.code}})
      nap 30
    end
  end

  def nlb_failed_page
    Page.from_tag_parts("PrivateLinkServiceNlbFailed", private_link_service.id)
  end

  label def ensure_listeners
    private_link_service.ports.each { ensure_listener(it) }
    hop_ensure_endpoint_service
  end

  # Found by tag before creating, so a run that died after the create call
  # makes no second service; the ubid is the idempotency token too.
  label def ensure_endpoint_service
    config = if service_id
      describe_service_configuration
    else
      created = find_service_configuration || create_service_configuration
      record_service_configuration(created)
      created
    end

    converge_service_configuration(config)
    hop_ensure_permissions
  end

  # Acceptance is always required: the approved endpoint list decides who
  # connects. The home region is implicit in AWS and never sent.
  def converge_service_configuration(config)
    params = {}
    params[:acceptance_required] = true unless config.acceptance_required

    # AWS keeps a removed region in the list with state Closed (and passes
    # through Deleting on the way). Those are not supported any more: asking
    # to remove one again fails with "Cannot remove region", and one the
    # database wants must be added back, not skipped.
    desired = aws_resource.supported_regions.to_a
    current = config.supported_regions
      .reject { INACTIVE_REGION_STATES.include?(it.service_state) }
      .map(&:region) - [private_link_service.location.name]
    add, remove = desired - current, current - desired
    params[:add_supported_regions] = add if add.any?
    params[:remove_supported_regions] = remove if remove.any?
    return if params.empty?

    ec2_client.modify_vpc_endpoint_service_configuration(service_id:, **params)
    Clog.emit("private link service configuration updated", {private_link_service_configuration: {ubid: private_link_service.ubid, **params}})
  end

  label def ensure_permissions
    converge_permissions
    hop_ensure_connections
  end

  label def ensure_connections
    converge_connections
    hop_ensure_private_dns
  end

  def converge_permissions
    desired = private_link_service.allowed_principals.to_a
    current = ec2_client.describe_vpc_endpoint_service_permissions(service_id:)
      .flat_map { |page| page.allowed_principals.map(&:principal) }

    add, remove = desired - current, current - desired
    return if add.empty? && remove.empty?

    params = {service_id:}
    params[:add_allowed_principals] = add if add.any?
    params[:remove_allowed_principals] = remove if remove.any?
    ec2_client.modify_vpc_endpoint_service_permissions(**params)
    Clog.emit("private link service permissions updated", {private_link_service_permissions: {ubid: private_link_service.ubid, added: add, removed: remove}})
  end

  # AWS checks the TXT record only when asked, and only once it is live on the
  # DNS servers; verify_private_dns picks up whatever is left.
  label def ensure_private_dns
    config = describe_service_configuration
    desired = private_link_service.private_dns_name

    if config.private_dns_name != desired
      unpublish_private_dns_record
      params = {service_id:}
      if desired
        params[:private_dns_name] = desired
      else
        params[:remove_private_dns_name] = true
      end
      ec2_client.modify_vpc_endpoint_service_configuration(**params)
      Clog.emit("private link service private DNS name updated", {private_link_service_private_dns: {ubid: private_link_service.ubid, from: config.private_dns_name, to: desired}})
      config = describe_service_configuration
    end

    record_private_dns(config)

    if desired && !aws_resource.private_dns_verified?
      zone = private_link_service.managed_private_dns_zone
      if zone && publish_private_dns_record(zone) == :live
        start_private_dns_verification
        aws_resource.update(private_dns_verification_attempted_at: Time.now)
      end
    end

    Clog.emit("private link service reconciled", private_link_service)
    hop_wait
  end

  label def wait
    when_reconcile_set? do
      decr_reconcile
      register_deadline("wait", 15 * 60)
      hop_ensure_target_groups
    end

    when_update_permissions_set? do
      register_deadline("wait", 10 * 60)
      hop_update_permissions
    end

    when_reconcile_connections_set? do
      register_deadline("wait", 10 * 60)
      hop_reconcile_connections
    end

    hop_verify_private_dns if aws_resource.private_dns_verification_due?

    nap (private_link_service.private_dns_name && !aws_resource.private_dns_verified?) ? PrivateLinkServiceAwsResource::PRIVATE_DNS_VERIFICATION_INTERVAL : IDLE_NAP
  end

  label def update_permissions
    converge_permissions
    decr_update_permissions
    hop_wait
  end

  label def reconcile_connections
    if service_id
      converge_service_configuration(describe_service_configuration)
      converge_connections
    end
    decr_reconcile_connections
    hop_wait
  end

  label def verify_private_dns
    if service_id && private_link_service.private_dns_name
      record_private_dns(describe_service_configuration)

      unless aws_resource.private_dns_verified?
        zone = private_link_service.managed_private_dns_zone
        published = zone && publish_private_dns_record(zone)
        nap PRIVATE_DNS_RECORD_SETTLE_SECONDS if published == :pending
        start_private_dns_verification if aws_resource.private_dns_verification_name
      end
    end

    aws_resource.update(private_dns_verification_attempted_at: Time.now)
    hop_wait
  end

  label def destroy
    decr_destroy
    register_deadline(nil, 15 * 60)
    nlb_failed_page&.incr_resolve
    hop_recover_unrecorded_ids
  end

  label def recover_unrecorded_ids
    recover_nlb_arn
    private_link_service.ports.each { recover_target_group_arn(it) }
    recover_listener_arns
    recover_service_id
    hop_delete_endpoint_service
  end

  def recover_nlb_arn
    return if nlb_arn

    arn = elbv2_client.describe_load_balancers(names: [nlb_name]).load_balancers.first.load_balancer_arn
    aws_resource.update(nlb_arn: arn)
    log_recovered("nlb", arn)
  rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
    nil
  end

  def recover_target_group_arn(port)
    return if port_aws(port).target_group_arn

    arn = elbv2_client.describe_target_groups(names: [target_group_name(port)]).target_groups.first.target_group_arn
    port_aws(port).update(target_group_arn: arn)
    log_recovered("target_group", arn, port: port.port)
  rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
    nil
  end

  # Listeners have no name of their own: they are found by port on the NLB.
  def recover_listener_arns
    ports = private_link_service.ports.reject { port_aws(it).listener_arn }
    return if ports.empty? || !nlb_arn

    listeners = elbv2_client.describe_listeners(load_balancer_arn: nlb_arn).listeners
    ports.each do |port|
      next unless (listener = listeners.find { it.port == port.port })

      port_aws(port).update(listener_arn: listener.listener_arn)
      log_recovered("listener", listener.listener_arn, port: port.port)
    end
  rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
    nil
  end

  def recover_service_id
    return if service_id
    return unless (config = find_service_configuration)

    record_service_configuration(config)
    log_recovered("endpoint_service", config.service_id)
  end

  def log_recovered(kind, id, **extra)
    Clog.emit("private link service recovered an unrecorded AWS resource", {private_link_service_recovered: {ubid: private_link_service.ubid, kind:, id:, **extra}})
  end

  label def delete_endpoint_service
    if service_id
      failure = ec2_client.delete_vpc_endpoint_service_configurations(service_ids: [service_id]).unsuccessful.first
      if failure && !failure.error.code.end_with?("NotFound")
        Clog.emit("private link service configuration not deletable yet", {private_link_service_delete_blocked: {ubid: private_link_service.ubid, service_id:, code: failure.error.code, message: failure.error.message}})
        reject_connections
        nap 10
      end
    end

    hop_wait_service_gone
  end

  label def wait_service_gone
    if service_id
      begin
        config = ec2_client.describe_vpc_endpoint_service_configurations(service_ids: [service_id]).service_configurations.first
        nap 10 if config && config.service_state != "Deleted"
      rescue Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound
        Clog.emit("private link service configuration already gone", {private_link_service_config_missing: {service_id:}})
      end

      unpublish_private_dns_record
    end

    hop_delete_listeners
  end

  label def delete_listeners
    private_link_service.ports.each { delete_listener(it) }
    hop_delete_target_groups
  end

  label def delete_target_groups
    private_link_service.ports.each { delete_target_group(it) }
    hop_delete_nlb
  end

  label def delete_nlb
    if nlb_arn
      begin
        elbv2_client.delete_load_balancer(load_balancer_arn: nlb_arn)
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        Clog.emit("private link service NLB already gone", {private_link_service_nlb_missing: {arn: nlb_arn}})
      rescue Aws::ElasticLoadBalancingV2::Errors::ResourceInUse
        # Still referenced by the VPC endpoint service; retry once it is gone.
        Clog.emit("private link service NLB still in use", {private_link_service_nlb_in_use: {arn: nlb_arn}})
        nap 10
      end
    end

    hop_wait_nlb_gone
  end

  label def wait_nlb_gone
    if nlb_arn
      begin
        elbv2_client.describe_load_balancers(load_balancer_arns: [nlb_arn])
        nap 10
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        Clog.emit("private link service NLB gone", {private_link_service_nlb_gone: {arn: nlb_arn}})
      end
    end

    hop_wait_ports_gone
  end

  label def wait_ports_gone
    private_link_service.ports.each do |port|
      nap 10 unless port_gone?(port)
    end

    Clog.emit("private link service destroyed", private_link_service)
    private_link_service.destroy
    pop "private link service destroyed"
  end

  # NLB names: at most 32 characters, alphanumerics and hyphens.
  def nlb_name
    "pl-#{private_link_service.ubid[-20..]}"
  end

  def aws_subnet_ids
    private_link_service.private_subnet.private_subnet_aws_resource.aws_subnets.filter_map(&:subnet_id)
  end

  def nlb_security_group_ids
    [private_link_service.private_subnet.private_subnet_aws_resource.user_security_group_id].compact
  end

  def target_group_name(port)
    "pl-#{port.port}-#{private_link_service.ubid[-20..]}"
  end

  def ensure_target_group(port)
    return if port_aws(port).target_group_arn

    name = target_group_name(port)
    arn = begin
      elbv2_client.create_target_group(
        name:,
        protocol: "TCP",
        port: port.target_port,
        vpc_id:,
        target_type: "ip",
        ip_address_type: private_link_service.target_ip_address_type,
        health_check_protocol: "TCP",
        health_check_port: port.target_port.to_s,
        tags: Util.aws_tags(name, {"ubid" => private_link_service.ubid, "port" => port.port.to_s}),
      ).target_groups.first.target_group_arn
    rescue Aws::ElasticLoadBalancingV2::Errors::DuplicateTargetGroupName
      elbv2_client.describe_target_groups(names: [name]).target_groups.first.target_group_arn
    end

    port_aws(port).update(target_group_arn: arn)
  end

  NLB_ATTRIBUTES = [
    {key: "load_balancing.cross_zone.enabled", value: "true"},
  ].freeze

  TARGET_GROUP_ATTRIBUTES = [
    {key: "deregistration_delay.timeout_seconds", value: "0"},
    {key: "deregistration_delay.connection_termination.enabled", value: "true"},
  ].freeze

  # Attributes from the desired list whose value AWS does not report yet, so
  # a reconcile with everything in place only describes and never modifies.
  def missing_nlb_attributes(current, desired)
    current_values = current.to_h { [it.key, it.value] }
    desired.reject { current_values[it[:key]] == it[:value] }
  end

  def ensure_targets_for(port, desired_ips)
    return unless (arn = port_aws(port).target_group_arn)

    desired = desired_ips.map { {id: it, port: port.target_port} }
    current = elbv2_client.describe_target_health(target_group_arn: arn).target_health_descriptions
      .reject { it.target_health.state == "draining" }
      .map { {id: it.target.id, port: it.target.port} }

    if (to_add = desired - current).any?
      elbv2_client.register_targets(target_group_arn: arn, targets: to_add)
    end

    if (to_remove = current - desired).any?
      begin
        elbv2_client.deregister_targets(target_group_arn: arn, targets: to_remove)
      rescue Aws::ElasticLoadBalancingV2::Errors::InvalidTarget
        Clog.emit("stale target already deregistered", {private_link_service_target_deregister_race: {arn:, targets: to_remove}})
      end
    end
  end

  def ensure_listener(port)
    return if port_aws(port).listener_arn

    arn = begin
      elbv2_client.create_listener(
        load_balancer_arn: nlb_arn,
        protocol: "TCP",
        port: port.port,
        default_actions: [{type: "forward", target_group_arn: port_aws(port).target_group_arn}],
        tags: Util.aws_tags("#{nlb_name}-#{port.port}", {"ubid" => private_link_service.ubid, "port" => port.port.to_s}),
      ).listeners.first.listener_arn
    rescue Aws::ElasticLoadBalancingV2::Errors::DuplicateListener
      elbv2_client.describe_listeners(load_balancer_arn: nlb_arn).listeners.find { it.port == port.port }.listener_arn
    end

    port_aws(port).update(listener_arn: arn)
  end

  # Services in Deleting or Deleted state keep showing up in describe results
  # for a while after deletion and must not be mistaken for the live one.
  def find_service_configuration
    ec2_client.describe_vpc_endpoint_service_configurations(
      filters: [{name: "tag:ubid", values: [private_link_service.ubid]}],
    ).service_configurations.find { !%w[Deleting Deleted].include?(it.service_state) }
  end

  def supported_ip_address_types
    ((type = private_link_service.ip_address_type) == "dual") ? ["ipv4", "ipv6"] : [type]
  end

  def create_service_configuration
    params = {
      network_load_balancer_arns: [nlb_arn],
      acceptance_required: true,
      supported_ip_address_types:,
      client_token: private_link_service.ubid,
      tag_specifications: Util.aws_tag_specifications("vpc-endpoint-service", nlb_name, {"ubid" => private_link_service.ubid}),
    }
    params[:private_dns_name] = private_link_service.private_dns_name if private_link_service.private_dns_name
    regions = aws_resource.supported_regions.to_a
    params[:supported_regions] = regions unless regions.empty?
    ec2_client.create_vpc_endpoint_service_configuration(**params).service_configuration
  end

  def record_service_configuration(config)
    aws_resource.update(service_id: config.service_id, service_name: config.service_name)
    record_private_dns(config)
  end

  def describe_service_configuration
    ec2_client.describe_vpc_endpoint_service_configurations(service_ids: [service_id]).service_configurations.first
  end

  # Absent when the service has no private DNS name; nil.to_h is {}, which
  # clears the columns.
  def record_private_dns(config)
    dns = config.private_dns_name_configuration.to_h
    aws_resource.update(
      private_dns_verification_state: dns[:state],
      private_dns_verification_name: dns[:name],
      private_dns_verification_value: dns[:value],
    )
  end

  def start_private_dns_verification
    ec2_client.start_vpc_endpoint_service_private_dns_verification(service_id:)
    Clog.emit("private link service private DNS verification started", private_link_service)
  end

  # :live once the expected value has been the only live record for
  # PRIVATE_DNS_RECORD_SETTLE_SECONDS, :pending when it went in more recently,
  # nil while AWS has not issued the record.
  def publish_private_dns_record(zone)
    record_name = aws_resource.private_dns_verification_record_name
    value = aws_resource.private_dns_verification_value
    return unless record_name && value

    previous = aws_resource.private_dns_txt_record_name
    unpublish_private_dns_record if previous && previous != record_name

    newest = zone.records_dataset.where(name: "#{record_name}.", type: "TXT").order(:created_at, Sequel.desc(:tombstoned)).all.to_h { [it.data, it] }
    live = newest.reject { |_, row| row.tombstoned }
    if live.keys == [value]
      aws_resource.update(private_dns_txt_record_name: record_name) unless previous == record_name
      return (live[value].created_at > Time.now - PRIVATE_DNS_RECORD_SETTLE_SECONDS) ? :pending : :live
    end

    zone.delete_record(record_name:, type: "TXT") unless live.empty?
    zone.insert_record(record_name:, type: "TXT", ttl: PRIVATE_DNS_RECORD_TTL, data: value)
    aws_resource.update(private_dns_txt_record_name: record_name)
    Clog.emit("private link service private DNS TXT record published", {private_link_service_private_dns_record: {ubid: private_link_service.ubid, zone: zone.name, record_name:, value:}})
    :pending
  end

  # served_only: false, since the zone may have lost its servers since publishing.
  def unpublish_private_dns_record
    return unless (record_name = aws_resource.private_dns_txt_record_name)

    domain = record_name.split(".", 2).last
    if (zone = PrivateLinkService.managed_dns_zone_for(domain, served_only: false))
      zone.delete_record(record_name:, type: "TXT")
      Clog.emit("private link service private DNS TXT record removed", {private_link_service_private_dns_record: {ubid: private_link_service.ubid, zone: zone.name, record_name:}})
    end
    aws_resource.update(private_dns_txt_record_name: nil)
  end

  # Connection states in which the consumer still holds the service; AWS
  # refuses to delete a service while any connection is in one of these.
  ACTIVE_CONNECTION_STATES = %w[pendingAcceptance pending available].freeze

  # Connections AWS has let through: being set up or connected. Only these
  # are rejected when the endpoint is not approved; one still waiting for
  # acceptance is left waiting, since the owner may be about to approve it.
  ESTABLISHED_CONNECTION_STATES = %w[pending available].freeze

  # Accepts waiting connections from approved endpoints and rejects
  # established ones from any other; nothing is mirrored, every entry and
  # decision is logged.
  def converge_connections
    connections = describe_connections
    allowed = aws_resource.allowed_endpoints.to_h { [it.vpc_endpoint_id, it.description] }
    accept = connections.select { it.vpc_endpoint_state == "pendingAcceptance" && allowed.key?(it.vpc_endpoint_id) }.map(&:vpc_endpoint_id)
    reject = connections.select { ESTABLISHED_CONNECTION_STATES.include?(it.vpc_endpoint_state) && !allowed.key?(it.vpc_endpoint_id) }.map(&:vpc_endpoint_id)
    Clog.emit("private link service connections reconciled", {private_link_service_connections: {
      ubid: private_link_service.ubid, allowed:, accept:, reject:,
      connections: connections.map {
        {id: it.vpc_endpoint_id, owner: it.vpc_endpoint_owner, state: it.vpc_endpoint_state, ip_address_type: it.ip_address_type, created_at: it.creation_timestamp, note: allowed[it.vpc_endpoint_id]}
      },
    }})

    refused = []
    refused.concat(ec2_client.accept_vpc_endpoint_connections(service_id:, vpc_endpoint_ids: accept).unsuccessful) unless accept.empty?
    refused.concat(ec2_client.reject_vpc_endpoint_connections(service_id:, vpc_endpoint_ids: reject).unsuccessful) unless reject.empty?
    return if refused.empty?

    Clog.emit("private link service connection decisions refused", {private_link_service_connections_refused: {ubid: private_link_service.ubid, refused: refused.map { {id: it.resource_id, code: it.error.code, message: it.error.message} }}})
  end

  # Every page: a service can have more consumers than one page lists.
  def describe_connections
    ec2_client.describe_vpc_endpoint_connections(filters: [{name: "service-id", values: [service_id]}]).flat_map(&:vpc_endpoint_connections)
  end

  def reject_connections
    ids = describe_connections.select { ACTIVE_CONNECTION_STATES.include?(it.vpc_endpoint_state) }.map(&:vpc_endpoint_id)
    return if ids.empty?

    Clog.emit("rejecting endpoint connections before deleting the service", {private_link_service_reject_connections: {ubid: private_link_service.ubid, service_id:, vpc_endpoint_ids: ids}})
    ec2_client.reject_vpc_endpoint_connections(service_id:, vpc_endpoint_ids: ids)
  end

  # The deletes are idempotent through their NotFound rescues, so a retry
  # after a crash is safe with the ARNs still recorded.
  def delete_listener(port)
    return unless (arn = port_aws(port).listener_arn)

    elbv2_client.delete_listener(listener_arn: arn)
  rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
    Clog.emit("listener already gone", {private_link_service_listener_missing: {arn:, port: port.port}})
  end

  def delete_target_group(port)
    return unless (arn = port_aws(port).target_group_arn)

    elbv2_client.delete_target_group(target_group_arn: arn)
  rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
    Clog.emit("target group already gone", {private_link_service_target_group_missing: {arn:, port: port.port}})
  end

  def port_gone?(port)
    aws = port_aws(port)
    (aws.listener_arn.nil? || listener_gone?(aws.listener_arn)) && (aws.target_group_arn.nil? || target_group_gone?(aws.target_group_arn))
  end

  def listener_gone?(arn)
    elbv2_client.describe_listeners(listener_arns: [arn])
    false
  rescue Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound
    true
  end

  def target_group_gone?(arn)
    elbv2_client.describe_target_groups(target_group_arns: [arn])
    false
  rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
    true
  end
end
