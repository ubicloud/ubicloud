# frozen_string_literal: true

# Mixin for GCP strand programs that need to poll Long Running Operations (LROs)
# asynchronously instead of blocking with wait_until_done!.
#
# Usage in a strand program:
#
#   # Start an operation and store it:
#   op = compute_client.insert(project: ..., zone: ..., instance_resource: ...)
#   save_gcp_op(op.name, "zone", gcp_zone)
#   hop_wait_create
#
#   # Poll in the wait label:
#   label def wait_create
#     op = poll_gcp_op
#     nap 5 unless op.status == :DONE
#     raise "failed" if op_error?(op)
#     hop_next
#   end
module GcpLro
  # Save a GCP operation reference into the strand stack for later polling.
  #
  # @param op_name [String] the operation name from the GCP API
  # @param scope [String] "zone", "region", or "global"
  # @param scope_value [String, nil] the zone or region name (nil for global)
  def save_gcp_op(op_name, scope, scope_value = nil)
    update_stack({
      "gcp_op_name" => op_name,
      "gcp_op_scope" => scope,
      "gcp_op_scope_value" => scope_value
    })
  end

  # Clear stored GCP operation from the strand stack.
  def clear_gcp_op
    update_stack({
      "gcp_op_name" => nil,
      "gcp_op_scope" => nil,
      "gcp_op_scope_value" => nil
    })
  end

  # Poll the previously saved GCP operation and return its proto.
  #
  # @return [Google::Cloud::Compute::V1::Operation] the operation status
  def poll_gcp_op
    op_name = frame["gcp_op_name"]
    scope = frame["gcp_op_scope"]
    scope_value = frame["gcp_op_scope_value"]

    case scope
    when "zone"
      credential.zone_operations_client.get(
        project: gcp_project_id,
        zone: scope_value,
        operation: op_name
      )
    when "region"
      credential.region_operations_client.get(
        project: gcp_project_id,
        region: scope_value,
        operation: op_name
      )
    when "global"
      credential.global_operations_client.get(
        project: gcp_project_id,
        operation: op_name
      )
    else
      raise "Unknown GCP operation scope: #{scope}"
    end
  end

  # Check whether a completed operation has an error.
  def op_error?(op)
    op.respond_to?(:error) && op.error&.respond_to?(:errors) && !op.error.errors.empty?
  end

  # Build a human-readable error message from a completed operation.
  def op_error_message(op)
    err = op.error
    return err.to_s unless err.respond_to?(:errors)
    errors = err.errors.to_a
    return err.to_s if errors.empty?
    errors.map { |e| "#{e.message} (code: #{e.code})" }.join("; ")
  end

  # Extract the first error code from an operation's error details.
  def op_error_code(op)
    err = op.error
    return nil unless err.respond_to?(:errors)
    err.errors&.first&.code
  end
end
