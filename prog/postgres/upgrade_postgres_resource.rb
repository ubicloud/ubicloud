# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Postgres::UpgradePostgresResource < Prog::Base
  subject_is :postgres_resource

  label def start
    register_deadline("finish_upgrade", 2 * 60 * 60)
    hop_wait_for_standby
  end

  label def wait_for_standby
    candidate_server = PostgresServer[frame["candidate_server_id"]]

    nap 5 unless candidate_server.strand.label == "wait" && candidate_server.synchronization_status == "ready"

    hop_fence_primary
  end

  label def fence_primary
    primary_server = postgres_resource.representative_server

    # It's possible that the primary was already fenced (e.g. from a failed
    # upgrade attempt)
    primary_server.incr_fence unless primary_server.strand.label == "fence"

    hop_upgrade_standby
  end

  label def upgrade_standby
    candidate_server = PostgresServer[frame["candidate_server_id"]]
    target_version = postgres_resource.version.to_i + 1

    case candidate_server.vm.sshable.d_check("upgrade_postgres")
    when "Succeeded"
      candidate_server.vm.sshable.d_clean("upgrade_postgres")
      candidate_server.update(version: target_version)
      hop_update_metadata
    when "Failed", "NotStarted"
      candidate_server.vm.sshable.d_run("upgrade_postgres", "sudo", "postgres/bin/upgrade", target_version)
    end

    nap 5
  end

  label def update_metadata
    candidate_server = PostgresServer[frame["candidate_server_id"]]
    candidate_server.update(timeline_id: frame["new_timeline_id"])

    timeline = PostgresTimeline[frame["new_timeline_id"]]
    postgres_resource.update(
      version: candidate_server.version,
      timeline: timeline
    )
    candidate_server.incr_unplanned_take_over
    hop_wait_takeover
  end

  label def wait_takeover
    candidate_server = PostgresServer[frame["candidate_server_id"]]
    nap 5 unless candidate_server.strand.label == "wait"
    hop_finish_upgrade
  end

  label def finish_upgrade
    decr_upgrade
    pop "upgrade prog finished"
  end

  label def handle_failure
    Clog.emit("postgres_resource_upgrade_failed", resource_id: resource.id, reason: frame["failure_reason"])

    new_timeline = PostgresTimeline[frame["new_timeline_id"]]
    new_timeline.destroy

    candidate_server = PostgresServer[frame["candidate_server_id"]]
    candidate_server&.incr_destroy

    decr_upgrade
    pop "upgrade prog failed"
  end
end
