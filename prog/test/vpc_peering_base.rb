# frozen_string_literal: true

class Prog::Test::VpcPeeringBase < Prog::Test::PostgresBase
  frame_accessor :vpc_peering_id, :label_deadlines, :cascade_peering

  label def destroy_peered_postgres
    self.timeline_ids = postgres_resource.servers_dataset.distinct.select_map(:timeline_id)
    postgres_resource.incr_destroy
    hop_wait_peering_cascade
  end

  label def wait_resources_destroyed
    if (resource = postgres_resource || PrivateSubnet[private_subnet_id])
      wait_or_fail(15 * 60) { destroy_timeout(resource, 15) }
      # finish would destroy the project that still owns the resource.
      fail_test(fail_message)
    end
    verify_timelines_destroyed(timeline_ids) if timeline_ids
    hop_destroy_location
  end

  label def destroy_location
    Location[location_id].incr_destroy
    hop_wait_location_destroyed
  end

  label def wait_location_destroyed
    if (location = Location[location_id])
      wait_or_fail(10 * 60) { destroy_timeout(location, 10) }
      fail_test(fail_message)
    end
    hop_finish
  end

  def private_subnet
    @private_subnet ||= PrivateSubnet[private_subnet_id]
  end

  def vpc_peering
    @vpc_peering ||= ::VpcPeering[vpc_peering_id]
  end

  def destroy_timeout(resource, minutes)
    "#{resource.class} #{resource.ubid} was not destroyed within #{minutes} minutes (strand label: #{Strand.where(id: resource.id).get(:label) || "none"})"
  end

  # The peering can finish between the caller's existence check and this read.
  def peering_progress
    "#{vpc_peering.display_state} in #{Strand[vpc_peering_id]&.label}"
  end

  def record_failure(message)
    self.fail_message = fail_message ? "#{fail_message}; #{message}" : message
  end

  def wait_or_fail(seconds, message = nil)
    deadlines = label_deadlines || {}
    unless (deadline = deadlines[strand.label])
      deadline = Time.now.to_i + seconds
      self.label_deadlines = deadlines.merge(strand.label => deadline)
    end
    nap 5 if Time.now.to_i < deadline
    record_failure(message || yield)
  end
end
