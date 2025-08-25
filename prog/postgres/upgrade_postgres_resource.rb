# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Postgres::UpgradePostgresResource < Prog::Base
  subject_is :postgres_resource

  label def start
    register_deadline("finish_upgrade", 2 * 60 * 60)
    hop_wait_for_standby
  end

  label def wait_for_standby
    nap 5 unless candidate_server.strand.label == "wait" && candidate_server.synchronization_status == "ready"
    hop_wait_for_maintenance_window
  end

  label def wait_for_maintenance_window
    if postgres_resource.in_maintenance_window?
      postgres_resource.representative_server.incr_fence
      hop_wait_fence_primary
    end

    nap 10 * 60
  end

  label def wait_fence_primary
    nap 5 unless postgres_resource.representative_server.strand.label == "wait_fence"

    hop_upgrade_standby
  end

  label def upgrade_standby
    case candidate_server.vm.sshable.d_check("upgrade_postgres")
    when "Succeeded"
      candidate_server.vm.sshable.d_clean("upgrade_postgres")
      hop_update_metadata
    when "Failed"
      hop_upgrade_failed
    when "NotStarted"
      candidate_server.vm.sshable.d_run("upgrade_postgres", "sudo", "postgres/bin/upgrade", postgres_resource.desired_version)
    end

    nap 5
  end

  label def update_metadata
    candidate_server.update(version: postgres_resource.desired_version, timeline_id: new_timeline.id)

    postgres_resource.update(
      version: postgres_resource.desired_version,
      timeline: new_timeline
    )
    candidate_server.incr_refresh_walg_credentials
    candidate_server.incr_configure
    candidate_server.incr_restart
    candidate_server.incr_unplanned_take_over
    hop_wait_takeover
  end

  label def wait_takeover
    nap 5 unless candidate_server.strand.label == "wait" && postgres_resource.representative_server.id == candidate_server.id
    hop_prune_old_servers
  end

  label def prune_old_servers
    postgres_resource.servers.reject { it.version == postgres_resource.desired_version }.each { it.incr_destroy }
    hop_finish_upgrade
  end

  label def finish_upgrade
    pop "upgrade prog finished"
  end

  label def upgrade_failed
    if candidate_server
      logs = candidate_server.vm.sshable.cmd("sudo journalctl -u upgrade_postgres")
      logs.split("\n").each { |line| Clog.emit("Postgres resource upgrade failed") { {resource_id: postgres_resource.id, log: line} } }
      candidate_server.incr_destroy
    end

    new_timeline&.incr_destroy

    postgres_resource.representative_server.incr_unfence if postgres_resource.representative_server.strand.label == "wait_fence"
    nap 6 * 60 * 60
  end

  def candidate_server
    @candidate_server ||= PostgresServer[frame["candidate_server_id"]]
  end

  def new_timeline
    @new_timeline ||= PostgresTimeline[frame["new_timeline_id"]]
  end
end
