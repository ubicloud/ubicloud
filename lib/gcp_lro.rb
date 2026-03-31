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
    !op_http_error_code(op).nil? || op_errors(op).any?
  end

  # Build a human-readable error message from a completed operation.
  def op_error_message(op)
    errors = op_errors(op)
    messages = errors.map { |e| "#{e.message} (code: #{e.code})" }

    if (status = op_http_error_code(op))
      http_message = op.respond_to?(:http_error_message) ? op.http_error_message : nil
      label = "HTTP #{status}"
      messages.unshift((http_message && !http_message.empty?) ? "#{http_message} (#{label})" : label)
    end

    return messages.join("; ") unless messages.empty?

    err = op.respond_to?(:error) ? op.error : nil
    err&.to_s
  end

  private

  # Returns detailed operation errors as an array.
  def op_errors(op)
    return [] unless op.respond_to?(:error)
    err = op.error
    return [] unless err.respond_to?(:errors)
    Array(err.errors)
  end

  # Returns HTTP error status code for operations that fail at HTTP layer.
  def op_http_error_code(op)
    return nil unless op.respond_to?(:http_error_status_code)
    code = op.http_error_status_code
    return nil if code.nil? || code.zero?
    code
  end
end
