# frozen_string_literal: true

class Prog::Vnet::Gcp::SubnetNexus < Prog::Base
  include GcpLro
  include GcpFirewallPolicy

  subject_is :private_subnet

  CrmOperationError = GcpLro::CrmOperationError

  RFC1918_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].freeze
  # GCE internal IPv6 ranges used by dual-stack subnets (ULA space)
  GCE_INTERNAL_IPV6_RANGES = ["fd20::/20"].freeze

  # GCP Network Firewall Policy priority layout (one policy per VPC, flat 0-65535 space).
  # Lower number = higher precedence. Three bands:
  #
  #   1000-8998  Subnet ALLOW EGRESS: each subnet gets a pair (P for IPv4, P+1 for IPv6).
  #              Targeted via subnet secure tags so only member VMs are affected.
  #   10000+     Per-firewall INGRESS: tag-targeted rules managed by VpcUpdateFirewallRules.
  #              Each Ubicloud Firewall gets its own tag key; VMs bind to "active" tag values.
  #   65531-65534 VPC-wide DENY: unconditional deny for all private traffic (default-deny posture).
  #              Subnet/VM rules override these by having lower (= higher-precedence) priorities.
  #
  # See doc/gcp_firewall_architecture.md for the full design.
  ALLOW_SUBNET_BASE_PRIORITY = 1000

  label def start
    register_deadline("wait", 5 * 60)

    gcp_vpc = GcpVpc.where(project_id: private_subnet.project_id, location_id: private_subnet.location_id).first
    gcp_vpc ||= Prog::Vnet::Gcp::VpcNexus.assemble(private_subnet.project_id, private_subnet.location_id).subject
    unless private_subnet.gcp_vpc
      gcp_vpc.add_private_subnet(private_subnet)
      # Firewalls attached to this subnet (or to VMs whose NICs live in
      # it) may have been associated before the private_subnet_gcp_vpc
      # join row existed: the Postgres resource setup path creates
      # firewall+subnet+VM+firewall-attachment inside one DB transaction,
      # so every pre-existing fire_firewall_rules_update_for_vm_firewall
      # hook saw nic.private_subnet.gcp_vpc as nil. Fire the VPC sem
      # now that the join exists so VpcUpdateFirewallRules picks up the
      # firewalls that were missed.
      gcp_vpc.incr_update_firewall_rules
    end

    hop_wait_vpc_ready
  end

  label def wait_vpc_ready
    vpc = private_subnet.gcp_vpc
    if vpc.strand.label == "wait"
      hop_create_subnet
    end
    nap 5
  end

  label def create_subnet
    op = credential.subnetworks_client.insert(
      project: gcp_project_id,
      region: gcp_region,
      subnetwork_resource: Google::Cloud::Compute::V1::Subnetwork.new(
        name: subnet_name,
        description: "Ubicloud subnet for #{private_subnet.ubid} [Ubicloud=#{Config.provider_resource_tag_value}]",
        ip_cidr_range: private_subnet.net4.to_s,
        network: "projects/#{gcp_project_id}/global/networks/#{private_subnet.gcp_vpc.name}",
        private_ip_google_access: true,
        stack_type: "IPV4_IPV6",
        ipv6_access_type: "EXTERNAL",
      ),
    )
    save_gcp_op("create_subnet", op_name: op.name, scope: "region", scope_value: gcp_region)
    hop_wait_create_subnet
  rescue Google::Cloud::AlreadyExistsError
    # Retry after partial crash. Subnet already exists, proceed.
    hop_create_tag_resources
  end

  label def wait_create_subnet
    poll_and_clear_gcp_op("create_subnet") do |op|
      begin
        credential.subnetworks_client.get(project: gcp_project_id, region: gcp_region, subnetwork: subnet_name)
      rescue Google::Cloud::NotFoundError
        raise "GCP subnet #{subnet_name} creation failed: #{op_error_message(op)}"
      end
      Clog.emit("GCP LRO error but resource exists",
        {gcp_lro_recovered: {resource: "subnet #{subnet_name}", error: op_error_message(op)}})
    end
    hop_create_tag_resources
  end

  label def create_tag_resources
    tag_key_name = frame["tag_key_name"] || ensure_tag_key
    update_stack({"tag_key_name" => tag_key_name}) unless frame["tag_key_name"]

    subnet_tag_value_name = ensure_tag_value(tag_key_name, TAG_VALUE)
    update_stack({"subnet_tag_value_name" => subnet_tag_value_name})
    hop_create_subnet_allow_rules
  end

  label def create_subnet_allow_rules
    allocate_subnet_firewall_priority unless private_subnet.firewall_priority

    subnet_tag_value_name = frame["subnet_tag_value_name"]

    # Allow same-subnet IPv4 egress (overrides the VPC-wide deny-egress)
    ensure_firewall_policy_rule(
      priority: subnet_allow_priority,
      direction: "EGRESS",
      action: "allow",
      dest_ip_ranges: [private_subnet.net4.to_s],
      layer4_configs: [{ip_protocol: "all"}],
      target_secure_tags: [subnet_tag_value_name],
    )

    # Allow same-subnet IPv6 egress (overrides VPC-wide deny-egress-ipv6)
    ensure_firewall_policy_rule(
      priority: subnet_allow_priority + 1,
      direction: "EGRESS",
      action: "allow",
      dest_ip_ranges: [private_subnet.net6.to_s],
      layer4_configs: [{ip_protocol: "all"}],
      target_secure_tags: [subnet_tag_value_name],
    )

    hop_wait
  end

  label def wait
    when_refresh_keys_set? do
      # GCP has no IPsec tunnels. Nothing to rekey, just clear the semaphore.
      decr_refresh_keys
    end

    when_update_firewall_rules_set? do
      # Propagate to the VPC, which owns shared policy sync for GCP. No
      # per-VM fan-out: rule edits don't change tag bindings, so VMs
      # don't need to re-run UpdateFirewallRules. wait is only reachable
      # after start linked the subnet to its VPC, so gcp_vpc is present.
      private_subnet.gcp_vpc.incr_update_firewall_rules
      decr_update_firewall_rules
    end

    nap 10 * 60
  end

  label def destroy
    register_deadline("destroy", 5 * 60)
    decr_destroy
    private_subnet.remove_all_firewalls

    if private_subnet.nics.empty? && private_subnet.load_balancers.empty?
      delete_subnet_policy_rules
      delete_subnet_tag_resources

      begin
        op = credential.subnetworks_client.delete(
          project: gcp_project_id,
          region: gcp_region,
          subnetwork: subnet_name,
        )
        save_gcp_op("delete_subnet", op_name: op.name, scope: "region", scope_value: gcp_region)
        hop_wait_delete_subnet
      rescue Google::Cloud::NotFoundError
        nil
      rescue Google::Cloud::InvalidArgumentError => e
        raise unless e.message.include?("being used by")
        Clog.emit("GCP subnet still in use, retrying",
          {gcp_subnet_in_use: Util.exception_to_hash(e, into: {subnet: subnet_name})})
        nap 5
      end

      hop_finish_destroy
    else
      Semaphore.incr(
        private_subnet.nics_dataset.select(:id)
          .union(private_subnet.load_balancers_dataset.select(:id)),
        :destroy,
      )
      nap rand(5..10)
    end
  end

  label def wait_delete_subnet
    poll_and_clear_gcp_op("delete_subnet") do |op|
      begin
        credential.subnetworks_client.get(project: gcp_project_id, region: gcp_region, subnetwork: subnet_name)
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP subnet already gone despite LRO error; proceeding",
          {gcp_subnet_already_gone: {subnet: subnet_name, lro_error: op_error_message(op)}})
        next
      end
      raise "GCE subnet #{subnet_name} deletion LRO failed (subnet still present): #{op_error_message(op)}"
    end
    hop_finish_destroy
  end

  label def finish_destroy
    gcp_vpc = private_subnet.gcp_vpc
    private_subnet.destroy

    if gcp_vpc && gcp_vpc.private_subnets_dataset.empty?
      gcp_vpc.incr_destroy
    end

    pop "subnet destroyed"
  end

  private

  def firewall_policy_name
    private_subnet.gcp_vpc.name
  end

  def delete_subnet_policy_rules
    return unless private_subnet.firewall_priority

    subnet_cidrs = [private_subnet.net4.to_s, private_subnet.net6.to_s]
    [subnet_allow_priority, subnet_allow_priority + 1].each do |priority|
      existing = credential.network_firewall_policies_client.get_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:,
      )
      # Only delete if the rule belongs to this subnet (avoid deleting
      # another subnet's rule in case of a priority collision)
      next unless existing.match&.dest_ip_ranges&.any? { |r| subnet_cidrs.include?(r) }
      credential.network_firewall_policies_client.remove_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        priority:,
      )
    rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
      nil
    end
  end

  def delete_subnet_tag_resources
    tag_key = lookup_tag_key
    return unless tag_key

    subnet_tv = credential.crm_client
      .fetch_all(items: :tag_values) { |token, s| s.list_tag_values(parent: tag_key.name, page_token: token) }
      .find { |v| v.short_name == TAG_VALUE }
    credential.crm_client.delete_tag_value(subnet_tv.name) if subnet_tv

    # Per-subnet tag key. Always delete it when the subnet is destroyed.
    credential.crm_client.delete_tag_key(tag_key.name)
  rescue Google::Apis::ClientError => e
    case e.status_code
    when 404
      nil
    when 400
      # CRM returns HTTP 400 with a v2 error body whose `status` field is
      # FAILED_PRECONDITION when a tag value is still bound to resources
      # (ghost bindings lingering after VM/NIC deletion). Nap and retry.
      raise unless crm_error_status(e) == "FAILED_PRECONDITION"
      Clog.emit("Tag value still attached to resources, will retry",
        {tag_value_retry: Util.exception_to_hash(e, into: {tag_key: tag_key.name})})
      nap 15
    else
      raise
    end
  end

  def subnet_name
    "ubicloud-#{private_subnet.ubid}"
  end

  def subnet_allow_priority
    private_subnet.firewall_priority ||
      raise("subnet firewall_priority not allocated for #{private_subnet.ubid}")
  end

  def used_firewall_priorities_ds
    DB[:private_subnet]
      .where(project_id: private_subnet.project_id, location_id: private_subnet.location_id)
      .exclude(id: private_subnet.id)
      .exclude(firewall_priority: nil)
  end

  def allocate_subnet_firewall_priority
    used = used_firewall_priorities_ds.select_set(:firewall_priority)
    slot = (1000..8998).step(2).find { !used.include?(it) }

    raise "GCP firewall priority range exhausted for project #{private_subnet.project_id}" unless slot

    private_subnet.update(firewall_priority: slot)
  end

  def credential
    @credential ||= private_subnet.location.location_credential_gcp
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_region
    @gcp_region ||= private_subnet.location.name.delete_prefix("gcp-")
  end

  def tag_key_short_name
    "ubicloud-subnet-#{private_subnet.ubid}"
  end

  def tag_key_parent
    "projects/#{gcp_project_id}"
  end

  def ensure_tag_key
    ensure_crm_resource(
      pending_key: "pending_tag_key_crm_op",
      label: "Tag key",
      short_name: tag_key_short_name,
      lookup: -> { lookup_tag_key&.name },
    ) do
      credential.crm_client.create_tag_key(
        Google::Apis::CloudresourcemanagerV3::TagKey.new(
          short_name: tag_key_short_name,
          parent: tag_key_parent,
          purpose: "GCE_FIREWALL",
          purpose_data: {"network" => private_subnet.gcp_vpc.network_self_link},
          description: "Ubicloud subnet tag key [Ubicloud=#{Config.provider_resource_tag_value}]",
        ),
      )
    end
  end

  def lookup_tag_key
    credential.crm_client
      .fetch_all(items: :tag_keys) { |token, s| s.list_tag_keys(parent: tag_key_parent, page_token: token) }
      .find { |tk| tk.short_name == tag_key_short_name }
  end

  def ensure_tag_value(parent_tag_key_name, short_name)
    ensure_crm_resource(
      pending_key: "pending_tag_value_crm_op",
      label: "Tag value",
      short_name:,
      lookup: -> { lookup_tag_value_name(parent_tag_key_name, short_name) },
    ) do
      credential.crm_client.create_tag_value(
        Google::Apis::CloudresourcemanagerV3::TagValue.new(
          short_name:,
          parent: parent_tag_key_name,
          description: "Ubicloud subnet tag value [Ubicloud=#{Config.provider_resource_tag_value}]",
        ),
      )
    end
  end

  # The create block is called to start the LRO; `lookup` is a proc that
  # returns the resource name (string) on fallback lookup or nil.
  def ensure_crm_resource(pending_key:, label:, short_name:, lookup:)
    if (pending = frame[pending_key])
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({pending_key => nil})
      raise CrmOperationError.new(pending, op.error) if op.error
      name = op.response&.dig("name")
      return name if name
      return lookup.call ||
          raise("#{label} #{short_name} created but name not found in operation response or listing")
    end

    op = yield
    unless op.done?
      update_stack({pending_key => op.name})
      nap 5
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
    name = op.response&.dig("name")
    return name if name

    lookup.call ||
      raise("#{label} #{short_name} created but name not found in operation response or listing")
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup.call || raise("#{label} #{short_name} conflict but not found on lookup")
  rescue CrmOperationError => e
    # google.rpc.Code 6 = ALREADY_EXISTS. The CRM LRO can surface a
    # conflict via the operation's error Status instead of an HTTP 409,
    # typically on retries that create the same tag key/value concurrently.
    raise unless e.code == 6
    lookup.call || raise("#{label} #{short_name} conflict but not found on lookup")
  end

  def lookup_tag_value_name(parent_tag_key_name, short_name)
    credential.crm_client
      .fetch_all(items: :tag_values) { |token, s| s.list_tag_values(parent: parent_tag_key_name, page_token: token) }
      .find { |v| v.short_name == short_name }&.name
  end

  # Extracts the v2 error `status` field (e.g. "FAILED_PRECONDITION") from a
  # Google::Apis::ClientError body. google-apis-core builds ClientError
  # messages by prefixing `reason` (the v2 `status`) but we prefer reading
  # the structured body so we are not brittle to message-format changes.
  def crm_error_status(error)
    body = error.body
    return nil if body.nil? || body.empty?
    JSON.parse(body).dig("error", "status")
  rescue JSON::ParserError
    nil
  end
end
