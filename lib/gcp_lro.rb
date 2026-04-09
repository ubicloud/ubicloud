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
      "gcp_op_scope_value" => scope_value,
    })
  end

  # Clear stored GCP operation from the strand stack.
  def clear_gcp_op
    update_stack({
      "gcp_op_name" => nil,
      "gcp_op_scope" => nil,
      "gcp_op_scope_value" => nil,
    })
  end

  # Poll the previously saved GCP operation and return its proto.
  #
  # INVARIANT: Labels that call poll_gcp_op must only be entered after a
  # save_gcp_op(...); hop_<wait_label> sequence in the same strand. The
  # frame keys "gcp_op_name", "gcp_op_scope", and "gcp_op_scope_value"
  # are expected to be present; if the label is entered any other way,
  # this method will either raise ("Unknown GCP operation scope") or
  # issue a malformed request to GCP. Do NOT bypass save_gcp_op.
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
        operation: op_name,
      )
    when "region"
      credential.region_operations_client.get(
        project: gcp_project_id,
        region: scope_value,
        operation: op_name,
      )
    when "global"
      credential.global_operations_client.get(
        project: gcp_project_id,
        operation: op_name,
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
      http_message = op.http_error_message
      label = "HTTP #{status}"
      messages.unshift(http_message.empty? ? label : "#{http_message} (#{label})")
    end

    return messages.join("; ") unless messages.empty?

    op.error&.to_s
  end

  # Extract the first error code from an operation's error details.
  def op_error_code(op)
    op_errors(op).first&.code
  end

  # Poll the saved LRO, nap if still running, yield to a block if it errored,
  # and clear the op when done. The block receives the operation proto and is
  # responsible for any resource-specific recovery (GET the resource, hop back
  # on persistent failure, emit a recovery Clog, etc.). If the block falls
  # through (returns normally), we assume recovery succeeded and clear the op.
  # If the block needs to raise, nap, or hop, it should do so explicitly --
  # those control-flow exits unwind before clear_gcp_op.
  def poll_and_clear_gcp_op
    op = poll_gcp_op
    nap 5 unless op.status == :DONE
    yield op if op_error?(op)
    clear_gcp_op
    op
  end

  private

  # Returns detailed operation errors as an array. The Operation proto's
  # `error` submessage is nil when unset; otherwise its `errors` field is
  # always a repeated field.
  def op_errors(op)
    Array(op.error&.errors)
  end

  # Returns HTTP error status code for operations that fail at HTTP layer,
  # or nil when unset. The proto int32 field defaults to 0.
  def op_http_error_code(op)
    code = op.http_error_status_code
    code unless code.zero?
  end
end
