# frozen_string_literal: true

class Prog::Vnet::Gcp::UpdateFirewallRules < Prog::Base
  include GcpLro

  GCP_MAX_TAGS_PER_NIC = 10

  CrmOperationError = GcpCrmLro::CrmOperationError

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
    # If the VPC hasn't created a tag value yet (first-attach race), the
    # binding request returns HTTP 400 and the re-read-and-nap branch of
    # sync_tag_bindings retries until the VPC converges.
    desired_tag_values = vm.firewalls(eager: :firewall_rules).filter_map do |fw|
      firewall_tag_namespaced_name(fw) if fw.firewall_rules.any?
    end

    # Subnet "member" tag - without it, the VPC-wide DENY rules
    # (65531-65534) would block all private egress from this VM.
    subnet_tv = subnet_tag_namespaced_name
    desired_tag_values << subnet_tv

    # GCP limits each NIC to 10 secure tag bindings.
    if desired_tag_values.size > GCP_MAX_TAGS_PER_NIC
      Clog.emit("GCP NIC tag limit exceeded, truncating to #{GCP_MAX_TAGS_PER_NIC}",
        {gcp_nic_tag_limit: {vm: vm.name, desired: desired_tag_values.size, max: GCP_MAX_TAGS_PER_NIC}})
      fw_tags = desired_tag_values - [subnet_tv]
      desired_tag_values = fw_tags.first(GCP_MAX_TAGS_PER_NIC - 1) << subnet_tv
    end

    # Bind desired tags and unbind stale ones. If the NIC is at the 10-tag
    # limit and we queued failed creates for retry, sync_tag_bindings hops
    # to wait_tag_binding_deletes and re-enters this label when the delete
    # LROs complete.
    sync_tag_bindings(desired_tag_values)

    pop "firewall rule is added"
  end

  # Entered from sync_tag_bindings only when we both hit the GCE 10-tag NIC
  # limit on create AND have stale bindings to delete. GCE enforces the
  # limit at request time, so we must wait for the delete LROs to finish
  # before retrying the failed creates. otherwise the retries see the
  # same 10 bindings and fail again.
  label def wait_tag_binding_deletes
    frame["pending_tag_binding_deletes"]&.each do |op_name|
      op = regional_crm_client.get_operation(op_name)
      nap 5 unless op.done?
      raise CrmOperationError.new(op_name, op.error) if op.error
    end

    resource = vm_instance_resource_name
    frame["failed_creates_to_retry"]&.each do |tv|
      create_tag_binding(resource, tv)
    end

    update_stack({"pending_tag_binding_deletes" => nil, "failed_creates_to_retry" => nil})
    hop_update_firewall_rules
  end

  private

  def firewall_tag_namespaced_name(firewall)
    "#{credential.project_id}/ubicloud-fw-#{firewall.ubid}/active"
  end

  def subnet_tag_namespaced_name
    "#{credential.project_id}/ubicloud-subnet-#{vm.nic.private_subnet.ubid}/member"
  end

  # Tag binding
  def sync_tag_bindings(desired_tag_values)
    resource = vm_instance_resource_name

    resp = regional_crm_client.list_tag_bindings(parent: resource)
    existing = resp.tag_bindings || [].freeze

    # desired_tag_values is a set of namespaced names; list_tag_bindings
    # responses populate both tag_value (canonical) and tag_value_namespaced_name,
    # so we diff on the namespaced field.
    already_bound = existing.to_set(&:tag_value_namespaced_name)
    desired_set = desired_tag_values.to_set
    stale_bindings = existing.reject { |b| desired_set.include?(b.tag_value_namespaced_name) }
    new_tag_values = desired_tag_values.reject { |tv| already_bound.include?(tv) }

    # Create new bindings first to minimize the window where a VM lacks
    # required firewall/subnet tags. If creation fails with 400 (e.g. GCP
    # 10-tag NIC limit), queue for retry after freeing slots by deleting
    # stale bindings. Without stale bindings to free, the 400 is treated
    # as transient (tag value or instance eventual consistency has been
    # observed to take a few seconds) and we nap instead of raising;
    # re-raising would just generate strand_error noise on retries that
    # usually resolve on their own.
    failed_creates = []
    new_tag_values.each do |tv|
      create_tag_binding(resource, tv)
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 400
      if stale_bindings.any?
        failed_creates << tv
        next
      end
      # GCP periodically returns 400 on a create that actually landed -
      # fire-and-forget races between the create accept path and the
      # listing view. Re-read the bindings; if this tv is now present,
      # proceed. Only nap when the binding genuinely did not take.
      current = regional_crm_client.list_tag_bindings(parent: resource).tag_bindings
      next if current&.any? { |b| b.tag_value_namespaced_name == tv }
      Clog.emit("Tag binding 400 with binding not present, napping for retry",
        {tag_value: tv, parent: resource})
      nap 5
    end

    # Happy path: no capacity-driven retries queued. The deletes are
    # fire-and-forget because nothing here depends on the slots being
    # freed before we return.
    if failed_creates.empty?
      stale_bindings.each do |binding|
        regional_crm_client.delete_tag_binding(binding.name)
      rescue Google::Apis::ClientError => e
        raise unless e.status_code == 404
      end
      return
    end

    # Retry path: GCE checks the 10-tag NIC limit at request time, so a
    # synchronous retry would see the same 10 bindings unless the delete
    # LRO has already landed. Collect the delete op names and hop to
    # wait_tag_binding_deletes to poll them to DONE before retrying.
    pending_ops = []
    stale_bindings.each do |binding|
      op = regional_crm_client.delete_tag_binding(binding.name)
      pending_ops << op.name
    rescue Google::Apis::ClientError => e
      raise unless e.status_code == 404
    end

    update_stack({
      "pending_tag_binding_deletes" => pending_ops,
      "failed_creates_to_retry" => failed_creates,
    })
    hop_wait_tag_binding_deletes
  end

  def create_tag_binding(parent_resource, tag_value_namespaced_name)
    tag_binding_obj = Google::Apis::CloudresourcemanagerV3::TagBinding.new(
      parent: parent_resource,
      tag_value_namespaced_name:,
    )

    # Fire-and-forget. The binding completes asynchronously.
    regional_crm_client.create_tag_binding(tag_binding_obj)
  rescue Google::Apis::ClientError => e
    # 409 means the binding already exists: idempotent, swallow. 400 and
    # everything else propagate to sync_tag_bindings, which treats 400
    # specially (10-tag NIC cap / tag-value eventual consistency).
    raise unless e.status_code == 409
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

  # Shared helpers
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
