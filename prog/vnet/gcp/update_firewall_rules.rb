# frozen_string_literal: true

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  include GcpLro

  # Per-VM INGRESS rules start at priority 10000 in the VPC's network firewall policy.
  # These rules target per-firewall secure tags (ubicloud-fw-{firewall.ubid}/active),
  # so rules for different firewalls can share the same priority number -- GCP only
  # evaluates a rule for VMs bound to its target tag. Priorities are not stored in the
  # DB; they're allocated on-the-fly by reading the current policy and finding free slots.
  # See doc/gcp_firewall_architecture.md for the full priority band layout.
  TAG_RULE_BASE_PRIORITY = 10000
  GCP_MAX_TAGS_PER_NIC = 10

  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    # For each firewall attached to this VM:
    #   1. Ensure per-firewall tag key exists (GCE_FIREWALL purpose)
    #   2. Ensure 'active' tag value exists under that key
    #   3. Ensure shared policy rules exist for this firewall (INGRESS)
    #   4. Track tag value for binding
    #
    # fw_tag_data caches completed firewalls across nap restarts so we
    # don't re-process them when polling a pending CRM operation.
    fw_tag_data = frame["fw_tag_data"] || {}
    desired_tag_values = []

    vm.firewalls(eager: :firewall_rules).each do |fw|
      fw_rules = fw.firewall_rules

      if fw_tag_data[fw.ubid]
        tag_value_name = fw_tag_data[fw.ubid]
      else
        tag_key_name = ensure_firewall_tag_key(fw)
        tag_value_name = ensure_tag_value(tag_key_name, "active")

        # Always sync rules (even if empty) to clean up stale shared rules
        sync_firewall_rules(fw_rules, tag_value_name)
        fw_tag_data[fw.ubid] = tag_value_name
        update_stack({"fw_tag_data" => fw_tag_data, "pending_tag_key_crm_op" => nil, "pending_tag_value_crm_op" => nil})
      end

      # Only bind tag when there are active rules
      desired_tag_values << tag_value_name if fw_rules.any?
    end

    # Bind the subnet's "member" tag so this VM gets the subnet's EGRESS allow rules
    # (priorities 1000-8998, created by SubnetNexus#create_subnet_allow_rules).
    # Without this binding, the VPC-wide DENY rules (65531-65534) would block all
    # private egress from this VM.
    subnet_tv = lookup_subnet_tag_value
    desired_tag_values << subnet_tv if subnet_tv

    # GCP limits each NIC to 10 secure tag bindings.
    if desired_tag_values.size > GCP_MAX_TAGS_PER_NIC
      Clog.emit("GCP NIC tag limit exceeded, truncating to #{GCP_MAX_TAGS_PER_NIC}",
        {gcp_nic_tag_limit: {vm: vm.name, desired: desired_tag_values.size, max: GCP_MAX_TAGS_PER_NIC}})
      # Keep subnet tag if present, fill remaining slots with firewall tags
      if subnet_tv
        fw_tags = desired_tag_values - [subnet_tv]
        desired_tag_values = fw_tags.first(GCP_MAX_TAGS_PER_NIC - 1) << subnet_tv
      else
        desired_tag_values = desired_tag_values.first(GCP_MAX_TAGS_PER_NIC)
      end
    end

    # Bind desired tags and unbind stale ones
    sync_tag_bindings(desired_tag_values)

    # Clean up rules for firewalls no longer attached to any subnet
    cleanup_orphaned_firewall_rules

    pop "firewall rule is added"
  end

  private

  # --- Firewall tag key management ---

  def ensure_firewall_tag_key(firewall)
    short_name = "ubicloud-fw-#{firewall.ubid}"

    if (pending = frame["pending_tag_key_crm_op"]) && frame["pending_tag_key_fw_ubid"] == firewall.ubid
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_key_crm_op" => nil, "pending_tag_key_fw_ubid" => nil})
      raise "CRM operation #{pending} failed: #{op.error.message}" if op.error
      name = op.response&.dig("name")
      return name if name
      return lookup_tag_key_name(short_name) ||
          raise("Tag key #{short_name} created but name not found")
    end

    tag_key_obj = Google::Apis::CloudresourcemanagerV3::TagKey.new(
      short_name:,
      parent: tag_key_parent,
      purpose: "GCE_FIREWALL",
      purpose_data: {"network" => gcp_network_self_link_with_id},
    )

    op = credential.crm_client.create_tag_key(tag_key_obj)
    unless op.done?
      update_stack({"pending_tag_key_crm_op" => op.name, "pending_tag_key_fw_ubid" => firewall.ubid})
      nap 5
    end
    raise "CRM operation #{op.name} failed: #{op.error.message}" if op.error
    name = op.response&.dig("name")
    return name if name

    lookup_tag_key_name(short_name) ||
      raise("Tag key #{short_name} created but name not found")
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_key_name(short_name) ||
      raise("Tag key #{short_name} conflict but not found on lookup")
  rescue RuntimeError => e
    raise unless e.message.include?("ALREADY_EXISTS")
    lookup_tag_key_name(short_name) ||
      raise("Tag key #{short_name} conflict but not found on lookup")
  end

  def lookup_tag_key_name(short_name)
    resp = credential.crm_client.list_tag_keys(parent: tag_key_parent)
    resp.tag_keys&.find { |tk| tk.short_name == short_name }&.name
  end

  def ensure_tag_value(tag_key_name, short_name)
    if (pending = frame["pending_tag_value_crm_op"]) && frame["pending_tag_value_parent"] == tag_key_name
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_value_crm_op" => nil, "pending_tag_value_parent" => nil})
      raise "CRM operation #{pending} failed: #{op.error.message}" if op.error
      name = op.response&.dig("name")
      return name if name
      return lookup_tag_value_name(tag_key_name, short_name) ||
          raise("Tag value #{short_name} created but name not found")
    end

    tag_value_obj = Google::Apis::CloudresourcemanagerV3::TagValue.new(
      short_name:,
      parent: tag_key_name,
    )

    op = credential.crm_client.create_tag_value(tag_value_obj)
    unless op.done?
      update_stack({"pending_tag_value_crm_op" => op.name, "pending_tag_value_parent" => tag_key_name})
      nap 5
    end
    raise "CRM operation #{op.name} failed: #{op.error.message}" if op.error
    name = op.response&.dig("name")
    return name if name

    lookup_tag_value_name(tag_key_name, short_name) ||
      raise("Tag value #{short_name} created but name not found")
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_value_name(tag_key_name, short_name) ||
      raise("Tag value #{short_name} conflict but not found on lookup")
  rescue RuntimeError => e
    raise unless e.message.include?("ALREADY_EXISTS")
    lookup_tag_value_name(tag_key_name, short_name) ||
      raise("Tag value #{short_name} conflict but not found on lookup")
  end

  def lookup_tag_value_name(tag_key_name, short_name)
    resp = credential.crm_client.list_tag_values(parent: tag_key_name)
    resp.tag_values&.find { |v| v.short_name == short_name }&.name
  end

  def lookup_subnet_tag_value
    short_name = "ubicloud-subnet-#{vm.nic.private_subnet.ubid}"
    tag_key_name = lookup_tag_key_name(short_name)
    return unless tag_key_name
    lookup_tag_value_name(tag_key_name, "member")
  end

  # --- Tag-based policy rule sync ---
  # Per-firewall INGRESS rules are synced using content-based diffing: we compare
  # desired rules (from Ubicloud Firewall model) against existing policy rules
  # targeting the same tag value, ignoring priority. Stale rules are deleted,
  # missing rules are created with free priorities starting from TAG_RULE_BASE_PRIORITY.
  def sync_firewall_rules(fw_rules, tag_value_name)
    ip4_rules, ip6_rules = fw_rules.partition { |r| !r.ip6? }
    desired = build_tag_based_policy_rules(ip4_rules, tag_value_name:)
    desired += build_tag_based_policy_rules(ip6_rules, tag_value_name:)

    sync_tag_policy_rules(desired, tag_value_name)
  end

  def sync_tag_policy_rules(desired_rules, tag_value_name)
    policy = credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
    )

    all_rules = policy.rules || []
    existing_for_tag = all_rules.select { |r|
      r.action == "allow" &&
        r.target_secure_tags.any? { |t| t.name == tag_value_name }
    }

    # Match desired to existing by content (ignoring priority)
    remaining_existing = existing_for_tag.dup
    unmatched_desired = []

    desired_rules.each do |d|
      idx = remaining_existing.index { |e| tag_policy_rule_matches?(e, d) }
      if idx
        remaining_existing.delete_at(idx)
      else
        unmatched_desired << d
      end
    end

    # Delete unmatched existing rules
    remaining_existing.each { |e| delete_policy_rule(e.priority) }

    # Create unmatched desired rules with free priorities
    used = Set.new(all_rules.map(&:priority))
    remaining_existing.each { |e| used.delete(e.priority) }

    next_p = TAG_RULE_BASE_PRIORITY
    unmatched_desired.each do |d|
      next_p += 1 while used.include?(next_p)
      d[:priority] = next_p
      used << next_p
      create_tag_policy_rule(d)
      next_p += 1
    end
  end

  def create_tag_policy_rule(desired)
    retries = 0
    rule = build_tag_policy_rule(desired)
    begin
      credential.network_firewall_policies_client.add_rule(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
        firewall_policy_rule_resource: rule,
      )
    rescue Google::Cloud::AlreadyExistsError, Google::Cloud::InvalidArgumentError => e
      raise if e.is_a?(Google::Cloud::InvalidArgumentError) && !e.message.include?("same priorities")
      retries += 1
      raise if retries > 5
      Clog.emit("GCP firewall priority collision, retrying with new priority",
        {gcp_priority_collision: {firewall_policy: firewall_policy_name, priority: desired[:priority], retry: retries}})
      # Re-read policy to get current used priorities and pick a new slot
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
      used = Set.new((policy.rules || []).map(&:priority))
      next_p = TAG_RULE_BASE_PRIORITY
      next_p += 1 while used.include?(next_p)
      desired[:priority] = next_p
      rule = build_tag_policy_rule(desired)
      retry
    end
  end

  def delete_policy_rule(priority)
    credential.network_firewall_policies_client.remove_rule(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
      priority:,
    )
  rescue Google::Cloud::NotFoundError, Google::Cloud::InvalidArgumentError
    # Already deleted
  end

  # --- Tag binding ---

  def sync_tag_bindings(desired_tag_values)
    resource = vm_instance_resource_name

    resp = regional_crm_client.list_tag_bindings(parent: resource)
    existing = resp.tag_bindings || []

    already_bound = existing.map(&:tag_value).to_set
    desired_set = desired_tag_values.to_set
    stale_bindings = existing.reject { |b| desired_set.include?(b.tag_value) }
    new_tag_values = desired_tag_values.reject { |tv| already_bound.include?(tv) }

    # Create new bindings first to minimize the window where a VM lacks
    # required firewall/subnet tags. If creation fails with 400 (e.g. GCP
    # 10-tag NIC limit), queue for retry after freeing slots by deleting
    # stale bindings. Only retry when there are stale bindings to delete;
    # otherwise the 400 is not a capacity issue so re-raise immediately.
    # Note: catching broad 400 is safe because stale bindings are always
    # deleted anyway, and a non-capacity 400 will re-raise on retry since
    # create_tag_binding only swallows 409.
    failed_creates = []
    new_tag_values.each do |tv|
      create_tag_binding(resource, tv)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 400 && stale_bindings.any?
      failed_creates << tv
    end

    # Unbind stale tags (fire-and-forget -- the delete completes asynchronously)
    stale_bindings.each do |binding|
      regional_crm_client.delete_tag_binding(binding.name)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404
    end

    # Retry any creates that failed due to NIC tag limit
    failed_creates.each { |tv| create_tag_binding(resource, tv) }
  end

  def create_tag_binding(parent_resource, tag_value_name)
    tag_binding_obj = Google::Apis::CloudresourcemanagerV3::TagBinding.new(
      parent: parent_resource,
      tag_value: tag_value_name,
    )

    # Fire-and-forget -- the binding completes asynchronously.
    regional_crm_client.create_tag_binding(tag_binding_obj)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409 || e.status_code == 400
    return if e.status_code == 409
    raise
  end

  def vm_instance_resource_name
    @vm_instance_resource_name ||= begin
      instance = credential.compute_client.get(
        project: gcp_project_id,
        zone: gcp_zone,
        instance: vm.name,
      )
      # Tag Binding API requires project number (not project ID) and numeric instance ID
      "//compute.googleapis.com/projects/#{gcp_project_number}/zones/#{gcp_zone}/instances/#{instance.id}"
    end
  end

  # --- Orphaned firewall rule cleanup ---
  # When a firewall is detached from all subnets (or deleted), its shared
  # policy rules remain in the network firewall policy. This method finds
  # GCE_FIREWALL tag keys whose firewalls no longer have any subnet
  # associations and deletes the corresponding policy rules.

  def cleanup_orphaned_firewall_rules
    active_fw_ubids = vm.firewalls.map(&:ubid).to_set

    vpc_network_link = gcp_network_self_link_with_id

    resp = credential.crm_client.list_tag_keys(parent: tag_key_parent)
    fw_tag_keys = resp.tag_keys&.select { |tk|
      tk.short_name.start_with?("ubicloud-fw-") &&
        tk.purpose == "GCE_FIREWALL" &&
        tk.purpose_data&.dig("network") == vpc_network_link
    } || []

    orphaned_tag_keys = fw_tag_keys.reject { |tk|
      fw_ubid = tk.short_name.delete_prefix("ubicloud-fw-")
      next true if active_fw_ubids.include?(fw_ubid)
      fw = find_firewall(fw_ubid)
      fw&.private_subnets&.any? || DB[:firewalls_vms].where(firewall_id: fw&.id).any?
    }
    return if orphaned_tag_keys.empty?

    all_rules = nil

    orphaned_tag_keys.each do |tk|
      tag_value_name = lookup_tag_value_name(tk.name, "active")

      if tag_value_name
        all_rules ||= begin
          policy = credential.network_firewall_policies_client.get(
            project: gcp_project_id,
            firewall_policy: firewall_policy_name,
          )
          policy.rules || []
        end

        all_rules.each do |rule|
          next unless rule.action == "allow"
          next unless rule.target_secure_tags.any? { |t| t.name == tag_value_name }
          delete_policy_rule(rule.priority)
        end

        # Fire-and-forget: don't wait for CRM LRO -- ghost bindings can
        # cause 30-second waits that block the respirate thread.
        credential.crm_client.delete_tag_value(tag_value_name)
      end

      credential.crm_client.delete_tag_key(tk.name)
    end
  end

  # --- Rule builders ---

  def format_port_range(port_range)
    from = port_range.begin
    to = port_range.end - 1
    (from == to) ? from.to_s : "#{from}-#{to}"
  end

  def build_tag_based_policy_rules(rules, tag_value_name:)
    return [] if rules.empty?

    rules_by_cidr = rules.group_by { |r| r.cidr.to_s }
    desired = []

    rules_by_cidr.each do |cidr, cidr_rules|
      layer4_configs = cidr_rules.group_by(&:protocol).map do |proto, proto_rules|
        config = {ip_protocol: proto}
        # nil port_range means all ports — omit :ports entirely when any
        # rule in the group covers all ports so GCP treats it as "all".
        unless proto_rules.any? { |r| r.port_range.nil? }
          config[:ports] = proto_rules.map { |r| format_port_range(r.port_range) }
        end
        config
      end

      desired << {
        direction: "INGRESS",
        source_ranges: [cidr],
        target_secure_tags: [tag_value_name],
        layer4_configs:,
      }
    end

    desired
  end

  def build_tag_policy_rule(desired)
    layer4_configs = desired[:layer4_configs].map do |cfg|
      Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(
        ip_protocol: cfg[:ip_protocol],
        ports: cfg[:ports],
      )
    end

    Google::Cloud::Compute::V1::FirewallPolicyRule.new(
      priority: desired[:priority],
      direction: desired[:direction],
      action: "allow",
      match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
        src_ip_ranges: desired[:source_ranges],
        layer4_configs:,
      ),
      target_secure_tags: desired[:target_secure_tags].map { |t|
        Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: t)
      },
    )
  end

  def tag_policy_rule_matches?(existing, desired)
    matcher = existing.match
    return false unless matcher
    return false unless existing.direction == "INGRESS" && existing.action == "allow"
    return false unless matcher.src_ip_ranges.to_a.sort == desired[:source_ranges].sort

    existing_tags = existing.target_secure_tags.map(&:name).sort
    desired_tags = desired[:target_secure_tags].sort

    existing_tags == desired_tags &&
      matcher.layer4_configs.length == desired[:layer4_configs].length &&
      desired[:layer4_configs].all? { |d|
        matcher.layer4_configs.any? { |e|
          e.ip_protocol == d[:ip_protocol] && e.ports.to_a.sort == (d[:ports] || []).sort
        }
      }
  end

  # --- Shared helpers ---

  def credential
    @credential ||= vm.location.location_credential_gcp
  end

  # Compute instances are zonal resources, so the Tag Binding API
  # requires the zonal CRM endpoint (e.g. us-central1-a-cloudresourcemanager).
  def regional_crm_client
    @regional_crm_client ||= credential.regional_crm_client(gcp_zone)
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def gcp_project_number
    @gcp_project_number ||= begin
      project = credential.crm_client.get_project("projects/#{gcp_project_id}")
      project.name.delete_prefix("projects/")
    end
  end

  def find_firewall(fw_ubid)
    Firewall[fw_ubid]
  end

  def tag_key_parent
    "projects/#{gcp_project_id}"
  end

  def gcp_vpc
    @gcp_vpc ||= vm.nic.private_subnet.gcp_vpc
  end

  def gcp_network_self_link_with_id
    @gcp_network_self_link_with_id ||= gcp_vpc.network_self_link
  end

  def firewall_policy_name
    @firewall_policy_name ||= gcp_vpc.firewall_policy_name || gcp_vpc.name
  end

  def gcp_zone
    @gcp_zone ||= begin
      suffix = strand.stack.find { |f| f.key?("gcp_zone_suffix") }&.dig("gcp_zone_suffix") || "a"
      "#{gcp_region}-#{suffix}"
    end
  end

  def gcp_region
    @gcp_region ||= vm.location.name.delete_prefix("gcp-")
  end
end
