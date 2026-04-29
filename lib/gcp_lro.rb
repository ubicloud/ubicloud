# frozen_string_literal: true

# Mixin for GCP strand programs that need to poll Long Running Operations (LROs)
# asynchronously instead of blocking with wait_until_done!.
#
# Each LRO is stored under a named key in the strand's frame as a nested hash,
# allowing multiple in-flight LROs per strand.
#
# Usage in a strand program:
#
#   # Start an operation and store it:
#   op = compute_client.insert(project: ..., zone: ..., instance_resource: ...)
#   save_gcp_op(name: "create_vm", op_name: op.name, scope: "zone", scope_value: gcp_zone)
#   hop_wait_create
#
#   # Poll in the wait label:
#   label def wait_create
#     op = poll_gcp_op("create_vm")
#     nap 5 unless op.status == :DONE
#     raise "failed" if op_error?(op)
#     hop_next
#   end
module GcpLro
  # Error type for Cloud Resource Manager (CRM) long-running operations.
  # Carries the numeric google.rpc.Code enum (e.g. 6 = ALREADY_EXISTS,
  # 9 = FAILED_PRECONDITION) so callers can branch on the structured code
  # instead of parsing the human-readable message.
  class CrmOperationError < StandardError
    attr_reader :code

    def initialize(op_name, status)
      @code = status.code
      super("CRM operation #{op_name} failed: #{status.message}")
    end
  end

  # Save a GCP operation reference into the strand stack for later polling.
  #
  # @param name [String] logical name for this LRO slot
  # @param op_name [String] the operation name from the GCP API
  # @param scope [String] "zone", "region", or "global"
  # @param scope_value [String, nil] the zone or region name (nil for global)
  def save_gcp_op(name:, op_name:, scope:, scope_value: nil)
    update_stack(name => {
      "name" => op_name,
      "scope" => scope,
      "scope_value" => scope_value,
    })
  end

  def clear_gcp_op(name)
    update_stack(name => nil)
  end

  # Poll the previously saved GCP operation and return its proto.
  #
  # @param name [String] logical name for this LRO slot
  # @return [Google::Cloud::Compute::V1::Operation] the operation status
  def poll_gcp_op(name)
    op_name, scope, scope_value = frame[name].values_at("name", "scope", "scope_value")

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

  def op_error?(op)
    !op_http_error_code(op).nil? || op_errors(op).any?
  end

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

  def op_error_code(op)
    op_errors(op).first&.code
  end

  # Poll the saved LRO, nap if still running, yield to a block if it errored,
  # and clear the op when done. The block receives the operation proto and is
  # responsible for any resource-specific recovery (GET the resource, hop back
  # on persistent failure, emit a recovery Clog, etc.). If the block falls
  # through (returns normally), we assume recovery succeeded and clear the op.
  # If the block needs to raise, nap, or hop, it should do so explicitly.
  # Those control-flow exits unwind before clear_gcp_op.
  def poll_and_clear_gcp_op(name)
    op = poll_gcp_op(name)
    nap 5 unless op.status == :DONE
    yield op if op_error?(op)
    clear_gcp_op(name)
    op
  end

  private

  # Returns detailed operation errors as an array. The Operation proto's
  # `error` submessage is nil when unset; otherwise its `errors` field is
  # always a repeated field.
  def op_errors(op)
    op.error&.errors || [].freeze
  end

  # Returns HTTP error status code for operations that fail at HTTP layer,
  # or nil when unset. The proto int32 field defaults to 0.
  def op_http_error_code(op)
    code = op.http_error_status_code
    code unless code.zero?
  end
end
