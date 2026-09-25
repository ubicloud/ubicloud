# frozen_string_literal: true

# Keeps the daily partitions of deleted_record and the completed GitHub
# workflow tables ahead of today, and drops expired completed GitHub
# workflow partitions. Expired deleted_record partitions are archived
# and dropped by DeletedRecordArchiver.
class Prog::DeletedRecordPartitioner < Prog::Base
  RUNWAY_DAYS = 14      # Create partitions through this many days from today
  MIN_RUNWAY_DAYS = 7   # Runway at which to page
  RETENTION_DAYS = 44   # Number of past partitions to keep for github completed workflow run/job

  PARTITIONED_MODELS = [DeletedRecord, GithubCompletedWorkflowRun, GithubCompletedWorkflowJob].freeze

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
    PARTITIONED_MODELS.each do |model|
      runway = model.partition_runway_days
      if runway && runway < MIN_RUNWAY_DAYS
        Prog::PageNexus.assemble(
          "#{model.table_name} has only #{runway} days of partitions left",
          [page_tag(model)],
          strand.ubid,
          resource_id: strand.id,
          extra_data: {runway_days: runway, wanted_days: RUNWAY_DAYS},
        )
      end
    end

    hop_create_partitions
  end

  label def create_partitions
    through = Time.now.utc.to_date + RUNWAY_DAYS
    PARTITIONED_MODELS.each do |model|
      created = model.ensure_partitions(through:)
      Clog.emit("created #{model.table_name} partitions", {"#{model.table_name}_partitions_created": {days: created.map(&:to_s)}}) unless created.empty?
      Page.from_tag_parts(page_tag(model))&.incr_resolve
    end

    hop_drop_partitions
  end

  label def drop_partitions
    cutoff = Time.now.utc.to_date - RETENTION_DAYS
    [GithubCompletedWorkflowRun, GithubCompletedWorkflowJob].each do |model|
      expired = model.partition_days.select { it < cutoff }
      expired.each { model.drop_partition(it) }
      Clog.emit("dropped #{model.table_name} partitions", {"#{model.table_name}_partitions_dropped": {days: expired.map(&:to_s)}}) unless expired.empty?
    end

    self.partitions_ensured = true
    hop_wait
  end

  def page_tag(model)
    "#{model.name}PartitionRunway"
  end
end
