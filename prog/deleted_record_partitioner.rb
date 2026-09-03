# frozen_string_literal: true

# Keeps deleted_record's daily partitions ahead of today.
class Prog::DeletedRecordPartitioner < Prog::Base
  frame_accessor :partitions_ensured

  label def wait
    if partitions_ensured
      delete_from_stack("partitions_ensured")
      nap 24 * 60 * 60
    end

    register_deadline("wait", 10 * 60)
    hop_check_runway
  end

  label def check_runway
    runway = DeletedRecord.partition_runway_days
    if runway && runway < DeletedRecord::MIN_RUNWAY_DAYS
      Prog::PageNexus.assemble(
        "deleted_record has only #{runway} days of partitions left",
        ["DeletedRecordPartitionRunway"],
        strand.ubid,
        extra_data: {runway_days: runway, wanted_days: DeletedRecord::RUNWAY_DAYS},
      )
    else
      Page.from_tag_parts("DeletedRecordPartitionRunway")&.incr_resolve
    end

    hop_create_partitions
  end

  label def create_partitions
    created = DeletedRecord.ensure_partitions(through: Time.now.utc.to_date + DeletedRecord::RUNWAY_DAYS)
    Clog.emit("created deleted_record partitions", {deleted_record_partitions_created: {days: created.map(&:to_s)}}) unless created.empty?

    self.partitions_ensured = true
    hop_wait
  end
end
