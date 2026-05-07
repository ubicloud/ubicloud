# frozen_string_literal: true

class Prog::Vnet::Gcp::VpcUpdateFirewallRules < Prog::Base
  # Per-firewall INGRESS rules start at priority 10000 in the VPC's network
  # firewall policy. These rules target per-firewall secure tags
  # (ubicloud-fw-{firewall.ubid}/active). Tag targeting decides which VMs
  # evaluate a rule, but GCP rejects two rules at the same priority within
  # a policy, so priorities are globally unique. Each rule gets the next
  # free slot starting from TAG_RULE_BASE_PRIORITY, read from the live
  # policy. Priorities are not stored in the DB.
  # See doc/gcp_firewall_architecture.md for the full priority band layout.
  TAG_RULE_BASE_PRIORITY = 10000

  CrmOperationError = GcpLro::CrmOperationError

  subject_is :gcp_vpc

  def before_run
    # If the VPC is being torn down, exit without touching shared state:
    # VpcNexus#destroy runs orphan cleanup anyway, and reconciling policy
    # rules against a VPC mid-delete races the teardown.
    pop "firewall rules updated" if gcp_vpc.destroy_set?
  end

  label def update_firewall_rules
    # Enumerate every firewall reachable in this VPC: subnet-attached
    # firewalls from every private_subnet in the VPC, plus direct-VM
    # attachments via the VMs in those subnets' NICs. Dedupe by firewall
    # id; a single firewall may be attached to multiple subnets or to
    # both a subnet and a VM directly.
    #
    # fw_tag_data caches completed firewalls across nap restarts so we
    # don't re-process them when polling a pending CRM operation.
    fw_tag_data = frame["fw_tag_data"] || {}

    vpc_firewalls.each do |fw|
      if fw_tag_data[fw.ubid]
        next
      end

      tag_key_name = ensure_firewall_tag_key(fw)
      tag_value_name = ensure_tag_value(tag_key_name, GcpFirewallPolicy::TAG_VALUE)

      # VM side constructs the tag value's namespaced name
      # (project_id/ubicloud-fw-{ubid}/active) deterministically from the
      # firewall's ubid and binds by that form, so we do not persist the
      # canonical name across progs. We only use it locally in this label
      # run as target_secure_tags for the policy rules below (GCP's policy
      # rule API requires the canonical tagValues/{id} form).

      # Always sync rules (even if empty) to clean up stale shared rules
      # for a firewall whose rules just emptied out.
      sync_firewall_rules(fw.firewall_rules, tag_value_name)

      fw_tag_data[fw.ubid] = tag_value_name
      update_stack({"fw_tag_data" => fw_tag_data, "pending_tag_key_crm_op" => nil, "pending_tag_value_crm_op" => nil})
    end

    # Clean up rules for firewalls no longer attached to any subnet or
    # VM anywhere in this VPC.
    cleanup_orphaned_firewall_rules

    pop "firewall rules updated"
  end

  private

  # Returns every Firewall reachable in this VPC: union of subnet-attached
  # firewalls and direct-VM-attached firewalls. Deduped by firewall id,
  # with firewall_rules eagerly loaded so sync_firewall_rules can read
  # them without an N+1 query.
  def vpc_firewalls
    subnet_ids = DB[:private_subnet_gcp_vpc].where(gcp_vpc_id: gcp_vpc.id).select(:private_subnet_id)
    subnet_fw_ids = DB[:firewalls_private_subnets].where(private_subnet_id: subnet_ids).select(:firewall_id)
    vm_ids = DB[:nic].where(private_subnet_id: subnet_ids).exclude(vm_id: nil).select(:vm_id)
    vm_fw_ids = DB[:firewalls_vms].where(vm_id: vm_ids).select(:firewall_id)

    Firewall.eager(:firewall_rules)
      .where(id: subnet_fw_ids.union(vm_fw_ids, from_self: false))
      .all
  end

  def ensure_firewall_tag_key(firewall)
    short_name = "ubicloud-fw-#{firewall.ubid}"

    if (pending = frame["pending_tag_key_crm_op"]) && frame["pending_tag_key_fw_ubid"] == firewall.ubid
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_key_crm_op" => nil, "pending_tag_key_fw_ubid" => nil})
      raise CrmOperationError.new(pending, op.error) if op.error
      return op.response&.dig("name") || lookup_tag_key_name!(short_name)
    end

    tag_key_obj = Google::Apis::CloudresourcemanagerV3::TagKey.new(
      short_name:,
      parent: tag_key_parent,
      purpose: "GCE_FIREWALL",
      purpose_data: {"network" => gcp_network_self_link_with_id},
      description: "Ubicloud firewall tag key [Ubicloud=#{Config.provider_resource_tag_value}]",
    )

    op = credential.crm_client.create_tag_key(tag_key_obj)
    unless op.done?
      update_stack({"pending_tag_key_crm_op" => op.name, "pending_tag_key_fw_ubid" => firewall.ubid})
      nap 5
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
    op.response&.dig("name") || lookup_tag_key_name!(short_name)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_key_name!(short_name, "conflict but not found on lookup")
  rescue CrmOperationError => e
    # google.rpc.Code 6 = ALREADY_EXISTS. The CRM LRO can surface a
    # conflict via the operation's error Status instead of an HTTP 409.
    raise unless e.code == 6
    lookup_tag_key_name!(short_name, "conflict but not found on lookup")
  end

  def lookup_tag_key_name(short_name)
    credential.crm_client
      .fetch_all(items: :tag_keys) { |token, s| s.list_tag_keys(parent: tag_key_parent, page_token: token) }
      .find { |tk| tk.short_name == short_name }&.name
  end

  def lookup_tag_key_name!(short_name, label = "created but name not found")
    lookup_tag_key_name(short_name) || raise("Tag key #{short_name} #{label}")
  end

  def ensure_tag_value(tag_key_name, short_name)
    if (pending = frame["pending_tag_value_crm_op"]) && frame["pending_tag_value_parent"] == tag_key_name
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      update_stack({"pending_tag_value_crm_op" => nil, "pending_tag_value_parent" => nil})
      raise CrmOperationError.new(pending, op.error) if op.error
      return op.response&.dig("name") || lookup_tag_value_name!(tag_key_name, short_name)
    end

    tag_value_obj = Google::Apis::CloudresourcemanagerV3::TagValue.new(
      short_name:,
      parent: tag_key_name,
      description: "Ubicloud firewall tag value [Ubicloud=#{Config.provider_resource_tag_value}]",
    )

    op = credential.crm_client.create_tag_value(tag_value_obj)
    unless op.done?
      update_stack({"pending_tag_value_crm_op" => op.name, "pending_tag_value_parent" => tag_key_name})
      nap 5
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
    op.response&.dig("name") || lookup_tag_value_name!(tag_key_name, short_name)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_value_name!(tag_key_name, short_name, "conflict but not found on lookup")
  rescue CrmOperationError => e
    # google.rpc.Code 6 = ALREADY_EXISTS. The CRM LRO can surface a
    # conflict via the operation's error Status instead of an HTTP 409.
    raise unless e.code == 6
    lookup_tag_value_name!(tag_key_name, short_name, "conflict but not found on lookup")
  end

  def lookup_tag_value_name(tag_key_name, short_name)
    credential.crm_client
      .fetch_all(items: :tag_values) { |token, s| s.list_tag_values(parent: tag_key_name, page_token: token) }
      .find { |v| v.short_name == short_name }&.name
  end

  def lookup_tag_value_name!(tag_key_name, short_name, label = "created but name not found")
    lookup_tag_value_name(tag_key_name, short_name) || raise("Tag value #{short_name} #{label}")
  end

  # Per-firewall INGRESS rules are synced using content-based diffing: we compare
  # desired rules (from Ubicloud Firewall model) against existing policy rules
  # targeting the same tag value, ignoring priority. Stale rules are deleted,
  # missing rules are created with free priorities starting from TAG_RULE_BASE_PRIORITY.
  def sync_firewall_rules(fw_rules, tag_value_name)
    sync_tag_policy_rules(build_tag_based_policy_rules(fw_rules, tag_value_name:), tag_value_name)
  end

  def sync_tag_policy_rules(desired_rules, tag_value_name)
    policy = credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
    )

    all_rules = policy.rules || [].freeze

    # Match desired to existing by content (ignoring priority)
    remaining_existing = all_rules.select { |r|
      r.action == "allow" &&
        r.target_secure_tags.any? { |t| t.name == tag_value_name }
    }
    unmatched_desired = []

    desired_rules.each do |d|
      idx = remaining_existing.index { |e| tag_policy_rule_matches?(e, d) }
      if idx
        remaining_existing.delete_at(idx)
      else
        unmatched_desired << d
      end
    end

    remaining_existing.each { |e| delete_policy_rule(e.priority) }

    used = Set.new(all_rules, &:priority)
    remaining_existing.each { |e| used.delete(e.priority) }

    next_p = TAG_RULE_BASE_PRIORITY
    unmatched_desired.each do |d|
      next_p += 1 while used.include?(next_p)
      d[:priority] = next_p
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
      # Re-read policy to get current used priorities and pick a new slot.
      # Start the scan past the priority that just collided; rescanning from
      # TAG_RULE_BASE_PRIORITY wastes O(N) integer checks on slots we
      # already know are taken. Priority collisions should be rare now that
      # shared work runs from a single VPC-level writer, but the retry
      # remains here for the subnet-add_rule LRO-in-flight edge case.
      policy = credential.network_firewall_policies_client.get(
        project: gcp_project_id,
        firewall_policy: firewall_policy_name,
      )
      used = Set.new(policy.rules, &:priority)
      next_p = desired[:priority] + 1
      next_p += 1 while used.include?(next_p) && next_p <= 65535
      raise "No available firewall policy priority slot <= 65535 for #{firewall_policy_name}" if next_p > 65535
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
    nil
  end

  # When a firewall is detached from all subnets and VMs (or deleted), its
  # shared policy rules remain in the network firewall policy. This method
  # finds GCE_FIREWALL tag keys for this VPC whose firewalls no longer have
  # any subnet or VM associations and deletes the corresponding policy
  # rules, tag value, and tag key.
  def cleanup_orphaned_firewall_rules
    active_fw_ubids = vpc_firewalls.to_set(&:ubid)

    vpc_network_link = gcp_network_self_link_with_id

    fw_tag_keys = credential.crm_client
      .fetch_all(items: :tag_keys) { |token, s| s.list_tag_keys(parent: tag_key_parent, page_token: token) }
      .select { |tk|
        tk.short_name.start_with?("ubicloud-fw-") &&
          tk.purpose == "GCE_FIREWALL" &&
          tk.purpose_data&.dig("network") == vpc_network_link
      }

    # Pair each non-active candidate tag key with its parsed firewall UUID.
    # Malformed ubids yield nil and are always treated as orphaned.
    candidates = fw_tag_keys.filter_map { |tk|
      fw_ubid = tk.short_name.delete_prefix("ubicloud-fw-")
      next if active_fw_ubids.include?(fw_ubid)
      [tk, UBID.to_uuid(fw_ubid)]
    }
    return if candidates.empty?

    # Defensive UNION query: a firewall attached in another VPC must not
    # be treated as orphaned here. The active-set above is scoped to this
    # VPC, but this query re-confirms global attachments.
    candidate_uuids = candidates.filter_map(&:last)
    active_ids = DB[:firewalls_private_subnets].where(firewall_id: candidate_uuids).select(:firewall_id)
      .union(DB[:firewalls_vms].where(firewall_id: candidate_uuids).select(:firewall_id), from_self: false)
      .select_set(:firewall_id)

    orphaned_tag_keys = candidates.reject { |_tk, uuid| uuid && active_ids.include?(uuid) }.map(&:first)
    return if orphaned_tag_keys.empty?

    all_rules = nil

    orphaned_tag_keys.each do |tk|
      tag_value_name = lookup_tag_value_name(tk.name, GcpFirewallPolicy::TAG_VALUE)

      if tag_value_name
        all_rules ||= credential.network_firewall_policies_client.get(
          project: gcp_project_id,
          firewall_policy: firewall_policy_name,
        ).rules || [].freeze

        all_rules.each do |rule|
          next unless rule.action == "allow"
          next unless rule.target_secure_tags.any? { |t| t.name == tag_value_name }
          delete_policy_rule(rule.priority)
        end

        # Fire-and-forget: don't wait for CRM LRO. Ghost bindings can
        # cause 30-second waits that block the respirate thread.
        credential.crm_client.delete_tag_value(tag_value_name)
      end

      credential.crm_client.delete_tag_key(tk.name)
    end
  end

  def format_port_range(port_range)
    from = port_range.begin
    to = port_range.end - 1
    (from == to) ? from.to_s : "#{from}-#{to}"
  end

  def build_tag_based_policy_rules(rules, tag_value_name:)
    rules.group_by { |r| r.cidr.to_s }.map do |cidr, cidr_rules|
      layer4_configs = cidr_rules.group_by(&:protocol).map do |proto, proto_rules|
        config = {ip_protocol: proto}
        # nil port_range means all ports. Omit :ports entirely when any
        # rule in the group covers all ports so GCP treats it as "all".
        if proto_rules.all?(&:port_range)
          config[:ports] = proto_rules.map { |r| format_port_range(r.port_range) }
        end
        config
      end

      {
        direction: "INGRESS",
        source_ranges: [cidr],
        target_secure_tags: [tag_value_name],
        layer4_configs:,
      }
    end
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

    existing_tags = existing.target_secure_tags.map(&:name).sort!
    desired_tags = desired[:target_secure_tags].sort

    existing_tags == desired_tags &&
      matcher.layer4_configs.length == desired[:layer4_configs].length &&
      desired[:layer4_configs].all? { |d|
        matcher.layer4_configs.any? { |e|
          e.ip_protocol == d[:ip_protocol] && e.ports.to_a.sort == (d[:ports]&.sort || [].freeze)
        }
      }
  end

  def credential
    @credential ||= gcp_vpc.location.location_credential_gcp
  end

  def gcp_project_id
    @gcp_project_id ||= credential.project_id
  end

  def tag_key_parent
    "projects/#{gcp_project_id}"
  end

  def gcp_network_self_link_with_id
    @gcp_network_self_link_with_id ||= gcp_vpc.network_self_link
  end

  def firewall_policy_name
    gcp_vpc.name
  end
end
