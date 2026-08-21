# frozen_string_literal: true

class Prog::Vnet::Gcp::VpcUpdateFirewallRules < Prog::Base
  include GcpLro

  # Per-firewall INGRESS rules start at priority 10000 in the VPC's network
  # firewall policy. These rules target per-firewall secure tags
  # (ubicloud-fw-{firewall.ubid}/active). Tag targeting decides which VMs
  # evaluate a rule, but GCP rejects two rules at the same priority within
  # a policy, so priorities are globally unique. Each rule gets the next
  # free slot starting from TAG_RULE_BASE_PRIORITY, read from the live
  # policy. Priorities are not stored in the DB.
  # See doc/gcp_firewall_architecture.md for the full priority band layout.
  TAG_RULE_BASE_PRIORITY = 10000
  # 65531-65534 hold the VPC-wide deny rules; stay below them.
  TAG_RULE_MAX_PRIORITY = 65530

  # Self-imposed chunk size, well under GCP's documented ceiling of 5000
  # source ranges per rule, so a firewall whose rules span more distinct
  # CIDRs than this per (address family, port profile) group is split
  # into multiple packed rules.
  MAX_SOURCE_RANGES_PER_RULE = 256

  CrmOperationError = GcpLro::CrmOperationError

  subject_is :gcp_vpc
  frame_accessor :fw_tag_data, :policy_rule_ops, :policy_rule_ops_fw_ubid, :failed_fw_ubids,
    :pending_tag_key_crm_op, :pending_tag_key_fw_ubid,
    :pending_tag_value_crm_op, :pending_tag_value_parent, :pending_orphan_delete_crm_op

  def before_run
    return unless gcp_vpc.destroy_set?

    # Drain a pending mutation LRO before popping so a still-in-flight
    # add/remove doesn't race VpcNexus#destroy's policy deletion.
    # VpcNexus#destroy runs orphan cleanup anyway, and reconciling policy
    # rules against a VPC mid-delete races the teardown, so nothing else
    # in the label body runs. Await only: a page raised here would
    # outlive the VPC, and the frame this pops has no later reader.
    poll_policy_mutations(track_failures: false)

    # Nothing can act on a page naming a firewall in a VPC that is gone.
    Page.incr_resolve(Page.active.for_resource(gcp_vpc.id).select(:id))
    pop "firewall rules updated"
  end

  label def update_firewall_rules
    # Extends per entry, capped 30 minutes from the first, so a legacy
    # migration does not page but a stuck sync still does.
    register_deadline(nil, 5 * 60, allow_extension: 30 * 60)

    poll_policy_mutations

    # fw_tag_data caches tag value names across naps.
    fw_tag_data = self.fw_tag_data || {}

    skipped = failed_fw_ubids || [].freeze
    # Retrying a firewall whose add failed would nap on it forever and
    # starve the ones after it.
    firewalls = vpc_firewalls.reject { skipped.include?(it.ubid) }

    # Tag pairs for every firewall first: a VM waiting on a new
    # firewall's tag would otherwise queue behind the rule rounds of
    # every firewall ahead of it.
    firewalls.each do |fw|
      next if fw_tag_data[fw.ubid]
      tag_key_name = ensure_firewall_tag_key(fw)
      Clog.emit("GCP tag key created", {gcp_tag_key_created: tag_key_name})
      tag_value_name = ensure_tag_value(tag_key_name, GcpFirewallPolicy::TAG_VALUE)
      Clog.emit("GCP tag value created", {gcp_tag_value_created: tag_value_name})

      # The canonical tagValues/{id} cannot be derived from the ubid, so
      # it is cached here; the VM side binds by the namespaced name it
      # builds from the ubid instead.
      fw_tag_data[fw.ubid] = tag_value_name
      self.fw_tag_data = fw_tag_data
      self.pending_tag_key_crm_op = nil
      self.pending_tag_value_crm_op = nil
    end

    firewalls.each do |fw|
      # Sync even empty rule sets so stale rules of an emptied firewall
      # are cleaned up.
      tag_value_name = fw_tag_data[fw.ubid]
      sync_tag_policy_rules(build_tag_based_policy_rules(fw.firewall_rules, tag_value_name:), tag_value_name, fw.ubid)
    end

    # Clean up rules for firewalls no longer attached to any subnet or
    # VM anywhere in this VPC.
    cleanup_orphaned_firewall_rules

    unless skipped.empty?
      # The other firewalls have converged, so retry the failed ones on
      # the next entry rather than popping as if the policy matched.
      self.failed_fw_ubids = nil
      nap 60
    end

    pop "firewall rules updated"
  end

  private

  # Every Firewall reachable in this VPC: union of subnet-attached
  # firewalls and direct-VM-attached firewalls. Deduped by firewall id,
  # with firewall_rules eagerly loaded so the sync can read them without
  # an N+1 query. Read once per entry, like policy_rules.
  def vpc_firewalls
    @vpc_firewalls ||= begin
      subnet_ids = DB[:private_subnet_gcp_vpc].where(gcp_vpc_id: gcp_vpc.id).select(:private_subnet_id)
      subnet_fw_ids = DB[:firewalls_private_subnets].where(private_subnet_id: subnet_ids).select(:firewall_id)
      vm_ids = DB[:nic].where(private_subnet_id: subnet_ids).exclude(vm_id: nil).select(:vm_id)
      vm_fw_ids = DB[:firewalls_vms].where(vm_id: vm_ids).select(:firewall_id)

      Firewall.eager(:firewall_rules)
        .where(id: subnet_fw_ids.union(vm_fw_ids, from_self: false))
        .all
    end
  end

  def ensure_firewall_tag_key(firewall)
    short_name = "ubicloud-fw-#{firewall.ubid}"

    if (pending = pending_tag_key_crm_op) && pending_tag_key_fw_ubid == firewall.ubid
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      self.pending_tag_key_crm_op = nil
      self.pending_tag_key_fw_ubid = nil
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
      self.pending_tag_key_crm_op = op.name
      self.pending_tag_key_fw_ubid = firewall.ubid
      nap 5
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
    op.response&.dig("name") || lookup_tag_key_name!(short_name)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_key_name!(short_name, "conflict but not found on lookup")
  rescue CrmOperationError => e
    name = crm_op_conflict_name(e, short_name:) do
      lookup_tag_key_name!(short_name, "conflict but not found on lookup")
    end
    name || nap(5)
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
    if (pending = pending_tag_value_crm_op) && pending_tag_value_parent == tag_key_name
      op = credential.crm_client.get_operation(pending)
      unless op.done?
        nap 5
      end
      self.pending_tag_value_crm_op = nil
      self.pending_tag_value_parent = nil
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
      self.pending_tag_value_crm_op = op.name
      self.pending_tag_value_parent = tag_key_name
      nap 5
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
    op.response&.dig("name") || lookup_tag_value_name!(tag_key_name, short_name)
  rescue Google::Apis::ClientError => e
    raise unless e.status_code == 409
    lookup_tag_value_name!(tag_key_name, short_name, "conflict but not found on lookup")
  rescue CrmOperationError => e
    name = crm_op_conflict_name(e, short_name:) do
      lookup_tag_value_name!(tag_key_name, short_name, "conflict but not found on lookup")
    end
    name || nap(5)
  end

  def lookup_tag_value_name(tag_key_name, short_name)
    credential.crm_client
      .fetch_all(items: :tag_values) { |token, s| s.list_tag_values(parent: tag_key_name, page_token: token) }
      .find { |v| v.short_name == short_name }&.name
  end

  def lookup_tag_value_name!(tag_key_name, short_name, label = "created but name not found")
    lookup_tag_value_name(tag_key_name, short_name) || raise("Tag value #{short_name} #{label}")
  end

  def sync_tag_policy_rules(desired_rules, tag_value_name, fw_ubid)
    all_rules = policy_rules

    remaining_existing = all_rules.select { |r|
      r.direction == "INGRESS" && r.action == "allow" &&
        r.target_secure_tags.any? { |t| t.name == tag_value_name }
    }

    # Add every desired rule before removing any stale one so no CIDR
    # loses coverage mid-converge.
    adds = desired_rules.reject do |d|
      if (idx = remaining_existing.index { |e| tag_policy_rule_matches?(e, d) })
        remaining_existing.delete_at(idx)
      end
    end

    unless adds.empty?
      # Stale priorities still count as used until removed below.
      used = Set.new(all_rules, &:priority)
      mutations = adds.map do |desired|
        priority = next_free_priority(used)
        used << priority
        rule = build_tag_policy_rule(desired.merge(priority:))
        lambda do
          credential.network_firewall_policies_client.add_rule(
            project: gcp_project_id,
            firewall_policy: firewall_policy_name,
            firewall_policy_rule_resource: rule,
          )
        end
      end
      submit_policy_mutations(mutations, fw_ubid)
    end

    # Removes wait until every add lands so coverage never gaps.
    unless remaining_existing.empty?
      mutations = remaining_existing.map { |stale| -> { delete_policy_rule(stale.priority) } }
      submit_policy_mutations(mutations, fw_ubid)
    end
  end

  def next_free_priority(used)
    priority = TAG_RULE_BASE_PRIORITY
    priority += 1 while used.include?(priority) && priority <= TAG_RULE_MAX_PRIORITY
    raise "No available firewall policy priority slot <= #{TAG_RULE_MAX_PRIORITY} for #{firewall_policy_name}" if priority > TAG_RULE_MAX_PRIORITY
    priority
  end

  # Submits mutations without awaiting each LRO; op names are stored in
  # the frame for the next entry to poll. Pushback or a priority
  # collision defers the remaining mutations to the next rediff.
  def submit_policy_mutations(mutations, fw_ubid = nil)
    ops = []
    mutations.each do |mutation|
      op = begin
        mutation.call
      rescue Google::Cloud::Error => e
        retryable = policy_retryable?(e)
        # The frame is saved on nap, not on this raise, so an accepted
        # op dropped here would go untracked.
        raise if !retryable && ops.empty?
        if retryable
          Clog.emit("GCP firewall policy busy, deferring remaining mutations",
            {gcp_policy_busy: {policy: firewall_policy_name, error: e.message, error_class: e.class.name}})
        else
          Clog.emit("GCP firewall policy mutation rejected, deferring remaining mutations",
            {gcp_policy_rule_rejected: {policy: firewall_policy_name, error: e.message, error_class: e.class.name}})
        end
        store_policy_rule_ops(ops, fw_ubid)
        nap 5
      end
      next unless op
      Clog.emit("GCP firewall policy mutation submitted",
        {gcp_policy_rule_op_submitted: {policy: firewall_policy_name, operation: op.name}})
      ops << op.name
    end
    return if ops.empty?
    store_policy_rule_ops(ops, fw_ubid)
    nap 5
  end

  # Contention ("not ready", "same priorities", an already-created rule)
  # plus the transient server statuses. Anything else is this request
  # being rejected, which retrying will not fix.
  def policy_retryable?(error)
    case error
    when Google::Cloud::InvalidArgumentError
      error.message.include?("not ready") || error.message.include?("same priorities")
    when Google::Cloud::AlreadyExistsError, Google::Cloud::UnavailableError,
      Google::Cloud::InternalError, Google::Cloud::DeadlineExceededError
      true
    else
      false
    end
  end

  def store_policy_rule_ops(ops, fw_ubid)
    return if ops.empty?
    self.policy_rule_ops = ops
    self.policy_rule_ops_fw_ubid = fw_ubid
  end

  # Polls in-flight mutation ops, napping until all finish. A failed op
  # pages and drops its firewall from this convergence so the rest of
  # the VPC still syncs.
  def poll_policy_mutations(track_failures: true)
    return unless (ops = policy_rule_ops)

    fw_ubid = policy_rule_ops_fw_ubid
    errors = []
    pending = ops.reject do |op_name|
      op = begin
        credential.global_operations_client.get(project: gcp_project_id, operation: op_name)
      rescue Google::Cloud::NotFoundError
        Clog.emit("GCP firewall policy mutation op expired, rediffing",
          {gcp_policy_rule_op_gone: {policy: firewall_policy_name, operation: op_name}})
        next true
      end
      next false unless op.status == :DONE
      if op_error?(op)
        errors << op_error_message(op)
        Clog.emit("GCP firewall policy mutation failed, rediffing",
          {gcp_policy_rule_op_failed: {policy: firewall_policy_name, operation: op_name, error: op_error_message(op)}})
      else
        Clog.emit("GCP firewall policy mutation completed",
          {gcp_policy_rule_op_done: {policy: firewall_policy_name, operation: op_name}})
      end
      true
    end

    # Recorded before the nap below so a failure alongside a still-running
    # op is not lost when this entry exits.
    if track_failures && !errors.empty? && fw_ubid
      self.failed_fw_ubids = (failed_fw_ubids || []) | [fw_ubid]
      Prog::PageNexus.assemble(
        "GCP firewall policy mutation failed for firewall #{fw_ubid}",
        ["GcpFirewallPolicyMutationFailed", gcp_vpc.ubid, fw_ubid],
        gcp_vpc.ubid,
        resource_id: gcp_vpc.id,
        extra_data: {policy: firewall_policy_name, firewall: fw_ubid, errors:},
      )
    end

    unless pending.empty?
      store_policy_rule_ops(pending, fw_ubid)
      nap 5
    end

    self.policy_rule_ops = nil
    self.policy_rule_ops_fw_ubid = nil
  end

  def delete_policy_rule(priority)
    credential.network_firewall_policies_client.remove_rule(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
      priority:,
    )
  rescue Google::Cloud::InvalidArgumentError => e
    raise if e.message.include?("not ready")
    nil
  rescue Google::Cloud::NotFoundError
    nil
  end

  # When a firewall is detached from all subnets and VMs (or deleted), its
  # shared policy rules remain in the network firewall policy. This method
  # finds GCE_FIREWALL tag keys for this VPC whose firewalls no longer have
  # any subnet or VM associations and deletes the corresponding policy
  # rules, tag value, and tag key.
  def cleanup_orphaned_firewall_rules
    # Resume an in-flight delete first; the loop below is idempotent, so
    # after the poll the remaining work is re-derived from live state.
    poll_crm_delete(:pending_orphan_delete_crm_op)

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

    skipped = failed_fw_ubids || [].freeze

    orphaned_tag_keys.each do |tk|
      fw_ubid = tk.short_name.delete_prefix("ubicloud-fw-")
      # Resubmitting a remove that already failed would nap on it forever.
      next if skipped.include?(fw_ubid)

      # Dropped before the deletes below nap, so a reattach in a later
      # entry re-ensures the pair instead of syncing against a dead value.
      self.fw_tag_data = fw_tag_data.except(fw_ubid) if fw_tag_data&.key?(fw_ubid)

      tag_value_name = lookup_tag_value_name(tk.name, GcpFirewallPolicy::TAG_VALUE)

      if tag_value_name
        mutations = policy_rules.select { |rule|
          rule.action == "allow" && rule.target_secure_tags.any? { |t| t.name == tag_value_name }
        }.map { |rule| -> { delete_policy_rule(rule.priority) } }

        # Tracked like the sync path so pushback naps instead of raising,
        # and so the removes drain before the tag value delete below: a
        # value delete with rules still referencing it fails in its LRO.
        submit_policy_mutations(mutations, fw_ubid) unless mutations.empty?

        # The value must be confirmed deleted before the key delete is
        # submitted; a key delete with child values fails only in its LRO.
        submit_crm_delete(:pending_orphan_delete_crm_op) { credential.crm_client.delete_tag_value(tag_value_name) }
      end

      submit_crm_delete(:pending_orphan_delete_crm_op) { credential.crm_client.delete_tag_key(tk.name) }
    end
  end

  def format_port_range(port_range)
    from = port_range.begin
    to = port_range.end - 1
    (from == to) ? from.to_s : "#{from}-#{to}"
  end

  # "Source IP address ranges must contain either IPv4 or IPv6 CIDRs, not
  # a combination of both" (GCP firewall policy rule components), so pack
  # per (address family, port profile).
  def build_tag_based_policy_rules(rules, tag_value_name:)
    rules.group_by { |r| r.cidr.to_s }.group_by { |cidr, cidr_rules|
      [cidr.include?(":"), layer4_configs_for(cidr_rules)]
    }.flat_map do |(_, layer4_configs), cidr_groups|
      cidr_groups.map(&:first).sort.each_slice(MAX_SOURCE_RANGES_PER_RULE).map do |source_ranges|
        {
          direction: "INGRESS",
          source_ranges:,
          target_secure_tags: [tag_value_name],
          layer4_configs:,
        }
      end
    end
  end

  def layer4_configs_for(cidr_rules)
    cidr_rules.group_by(&:protocol).sort.map do |proto, proto_rules|
      {
        ip_protocol: proto,
        ports: proto_rules.map { |r| format_port_range(r.port_range) }.sort,
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
    # GCP compresses the longest IPv6 zero run, NetAddr the first, so
    # both sides are normalized or a /65-/128 range never matches.
    return false unless normalize_source_ranges(matcher.src_ip_ranges).sort == desired[:source_ranges].sort

    existing.target_secure_tags.map(&:name).sort == desired[:target_secure_tags].sort &&
      layer4_configs_eq?(matcher.layer4_configs, desired[:layer4_configs])
  end

  def normalize_source_ranges(ranges)
    ranges.to_a.map do |range|
      NetAddr.parse_net(range).to_s
    rescue NetAddr::ValidationError
      range
    end
  end

  def layer4_configs_eq?(existing_configs, desired_configs)
    existing_configs.length == desired_configs.length &&
      desired_configs.all? { |d|
        existing_configs.any? { |e|
          e.ip_protocol == d[:ip_protocol] && e.ports.to_a.sort == (d[:ports]&.sort || [].freeze)
        }
      }
  end

  # One read per entry, shared by every firewall and the orphan cleanup:
  # at most one phase mutates before napping, so it cannot go stale.
  def policy_rules
    @policy_rules ||= (credential.network_firewall_policies_client.get(
      project: gcp_project_id,
      firewall_policy: firewall_policy_name,
    ).rules || [].freeze).to_a
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
