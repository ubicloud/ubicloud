# frozen_string_literal: true

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  CrmOperationError = GcpLro::CrmOperationError
  GCP_MAX_TAGS_PER_VM = 10

  subject_is :vm

  def before_run
    # If the VM is being torn down, exit successfully even if rules were never
    # synced: the per-VM tag bindings are deleted with the instance, and any
    # leftover policy rules will be cleaned up by VpcUpdateFirewallRules
    # the next time a rule edit or attach lands on this VPC.
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    # Reconcile tag bindings for this VM. Shared VPC state (tag keys/values,
    # policy rules, orphan cleanup) is owned by VpcUpdateFirewallRules; we
    # only bind the per-firewall and subnet tags this VM needs.
    #
    # Tag values are referenced by their GCP "namespaced name"
    # (parent_id/tag_key_short_name/tag_value_short_name) instead of the
    # canonical tagValues/{numeric-id} form. Namespaced names are
    # deterministic from project_id + firewall.ubid + subnet.ubid, so the
    # VM side needs neither a DB column nor a CRM lookup to resolve them.
    desired_tag_values = vm.firewalls(eager: :firewall_rules).filter_map do |fw|
      firewall_tag_namespaced_name(fw) if fw.firewall_rules.any?
    end

    # Subnet "active" tag - without it, the VPC-wide DENY rules
    # (65531-65534) would block all private egress from this VM.
    desired_tag_values << subnet_tag_namespaced_name

    # Vm::Gcp#enforce_firewall_cap caps firewalls at 9 per GCP VM,
    # so with the subnet tag we are always <= 10. If we hit this, the
    # upstream cap validation regressed; fail loudly rather than silently
    # dropping tags.
    if desired_tag_values.size > GCP_MAX_TAGS_PER_VM
      raise "GCP VM tag limit exceeded for vm=#{vm.name} (desired=#{desired_tag_values.size}, max=#{GCP_MAX_TAGS_PER_VM}); Vm::Gcp#enforce_firewall_cap chain regressed"
    end

    resource = vm_instance_resource_name

    # Try to create every desired binding unconditionally. The only
    # trustworthy signal that a binding is durably persisted is GCP's
    # response to create_tag_binding: 200 (just created) or 409
    # (already exists). list_tag_bindings is read-side, eventually
    # consistent against an independent replica from the write side,
    # and can briefly report a binding as present that hasn't been
    # durably committed (or has just been rolled back). Trusting the
    # list to skip already-bound entries can mask a missed binding.
    #
    # 400 and 403 on create are eventual consistency, not capacity
    # (capacity is ruled out by the cap validation above): the parent
    # VM resource or the tag value hasn't yet propagated to the
    # regional CRM endpoint. Nap and retry. On the next iteration of
    # this label, GCP will return 200 (now visible, just created) or
    # 409 (already there from a prior attempt) - either way idempotent.
    desired_tag_values.each do |tv|
      create_tag_binding(resource, tv)
    rescue Google::Apis::ClientError => e
      raise unless [400, 403].include?(e.status_code)
      Clog.emit("Tag binding #{e.status_code}, napping for retry",
        {tag_value: tv, parent: resource})
      nap 5
    end

    # Stale-binding cleanup uses the list because a transiently-stale
    # entry only means we skip a delete that a subsequent run will
    # catch. That's harmless, unlike skipping a create.
    desired_set = desired_tag_values.to_set
    regional_crm_client
      .fetch_all(items: :tag_bindings) { |token, s| s.list_tag_bindings(parent: resource, page_token: token) }
      .each do |binding|
        next if desired_set.include?(binding.tag_value_namespaced_name)
        begin
          regional_crm_client.delete_tag_binding(binding.name)
        rescue Google::Apis::ClientError => e
          raise unless e.status_code == 404
        end
      end

    pop "firewall rule is added"
  end

  private

  def firewall_tag_namespaced_name(firewall)
    "#{credential.project_id}/ubicloud-fw-#{firewall.ubid}/#{GcpFirewallPolicy::TAG_VALUE}"
  end

  def subnet_tag_namespaced_name
    "#{credential.project_id}/ubicloud-subnet-#{vm.nic.private_subnet.ubid}/#{GcpFirewallPolicy::TAG_VALUE}"
  end

  def create_tag_binding(parent_resource, tag_value_namespaced_name)
    tag_binding_obj = Google::Apis::CloudresourcemanagerV3::TagBinding.new(
      parent: parent_resource,
      tag_value_namespaced_name:,
    )

    # Poll the long-running operation. The HTTP 200 from create_tag_binding
    # is a "regional accept", not a durability guarantee: regional CRM
    # buffers the write, then asynchronously confirms parent + tag value
    # visibility against global CRM, and can roll back the buffered write
    # on the way to op.done? if either is still propagating. We must wait
    # for op.done? and check op.error before declaring the binding bound.
    # See doc/gcp_firewall_architecture.md "Operation polling" section.
    op = regional_crm_client.create_tag_binding(tag_binding_obj)
    until op.done?
      sleep 1
      op = regional_crm_client.get_operation(op.name)
    end
    raise CrmOperationError.new(op.name, op.error) if op.error
  rescue Google::Apis::ClientError => e
    # 409 = binding already exists: idempotent, swallow. Everything else
    # (including 400) propagates to update_firewall_rules.
    raise unless e.status_code == 409
  rescue CrmOperationError => e
    # google.rpc.Code 6 = ALREADY_EXISTS, surfaces here when an in-flight
    # parallel binding completes between our create and our poll. Idempotent.
    raise unless e.code == 6
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

  def gcp_zone
    # gcp_zone_suffix lives in the bottom (root) frame of the strand stack,
    # set once by Vm::Gcp::Nexus when the VM is provisioned. UpdateFirewallRules
    # is always pushed as a child of that nexus, so reading from [-1] gives us
    # the parent frame's value.
    @gcp_zone ||= "#{gcp_region}-#{strand.stack[-1]["gcp_zone_suffix"] || "a"}"
  end

  def gcp_region
    @gcp_region ||= vm.location.name.delete_prefix("gcp-")
  end
end
