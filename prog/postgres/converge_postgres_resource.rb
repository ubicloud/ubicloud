# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Postgres::ConvergePostgresResource < Prog::Base
  subject_is :postgres_resource

  label def start
    register_deadline("wait_for_maintenance_window", 2 * 60 * 60)
    hop_provision_servers
  end

  label def provision_servers
    hop_wait_servers_to_be_ready if postgres_resource.has_enough_fresh_servers?

    if postgres_resource.servers.all? { it.vm.vm_host } || postgres_resource.location.aws?
      exclude_host_ids = []
      exclude_availability_zones = []
      availability_zone = nil
      if !Config.allow_unspread_servers && postgres_resource.location.provider == HostProvider::HETZNER_PROVIDER_NAME
        used_data_centers = postgres_resource.servers.map { it.vm.vm_host.data_center }.uniq
        exclude_host_ids = VmHost.where(data_center: used_data_centers).map(&:id)
      end

      if postgres_resource.location.provider == HostProvider::AWS_PROVIDER_NAME
        if postgres_resource.use_different_az_set?
          exclude_availability_zones = postgres_resource.servers.map { it.vm.nic.nic_aws_resource.subnet_az }.uniq
        else
          availability_zone = postgres_resource.representative_server.vm.nic.nic_aws_resource.subnet_az
        end
      end

      Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id, timeline_access: "fetch", exclude_host_ids: exclude_host_ids, exclude_availability_zones: exclude_availability_zones, availability_zone: availability_zone)
    end

    nap 5
  end

  label def wait_servers_to_be_ready
    hop_provision_servers unless postgres_resource.has_enough_fresh_servers?
    hop_wait_for_maintenance_window if postgres_resource.has_enough_ready_servers?

    nap 60
  end

  label def wait_for_maintenance_window
    nap 10 * 60 unless postgres_resource.in_maintenance_window?

    hop_provision_servers unless postgres_resource.has_enough_fresh_servers?

    if postgres_resource.version != postgres_resource.target_version
      postgres_resource.representative_server.incr_fence
      hop_wait_fence_primary
    end

    hop_recycle_representative_server
  end

  label def wait_fence_primary
    hop_upgrade_standby if postgres_resource.representative_server.strand.label == "wait_in_fence"

    nap 5
  end

  label def upgrade_standby
    case upgrade_candidate.vm.sshable.d_check("upgrade_postgres")
    when "Succeeded"
      upgrade_candidate.vm.sshable.d_clean("upgrade_postgres")
      hop_update_metadata
    when "Failed"
      hop_upgrade_failed
    when "NotStarted"
      upgrade_candidate.vm.sshable.d_run("upgrade_postgres", "sudo", "postgres/bin/upgrade", postgres_resource.target_version)
    end

    nap 5
  end

  label def update_metadata
    new_timeline_id = Prog::Postgres::PostgresTimelineNexus.assemble(
      location_id: postgres_resource.location_id
    ).id
    upgrade_candidate.update(version: postgres_resource.target_version, timeline_id: new_timeline_id, timeline_access: "push")

    upgrade_candidate.incr_refresh_walg_credentials
    upgrade_candidate.incr_configure
    upgrade_candidate.incr_restart

    hop_wait_upgrade_candidate
  end

  label def wait_upgrade_candidate
    nap 5 if upgrade_candidate.restart_set? || upgrade_candidate.strand.label != "wait"

    hop_recycle_representative_server
  end

  label def upgrade_failed
    if upgrade_candidate && !upgrade_candidate.destroy_set?
      logs = upgrade_candidate.vm.sshable.cmd("sudo journalctl -u upgrade_postgres")
      logs.split("\n").each { |line| Clog.emit("Postgres resource upgrade failed") { {resource_id: postgres_resource.id, log: line} } }
      upgrade_candidate.incr_destroy
      Prog::PageNexus.assemble("#{postgres_resource.ubid} upgrade failed", ["PostgresUpgradeFailed", postgres_resource.id], postgres_resource.ubid)
    end

    postgres_resource.representative_server.incr_unfence if postgres_resource.representative_server.strand.label == "wait_in_fence"
    nap 6 * 60 * 60
  end

  label def recycle_representative_server
    if (rs = postgres_resource.representative_server) && !postgres_resource.ongoing_failover?
      hop_prune_servers unless rs.needs_recycling?
      hop_provision_servers unless postgres_resource.has_enough_ready_servers?

      register_deadline(nil, 10 * 60)
      rs.trigger_failover(mode: "planned")
    end

    nap 60
  end

  label def prune_servers
    # Below we only keep servers that does not need recycling or are of the
    # current version. If there are more such servers than required, we prefer
    # ready and recent servers (in that order)
    servers_to_keep = postgres_resource.servers
      .reject { it.representative_at || it.needs_recycling? || it.version != postgres_resource.target_version }
      .sort_by { [(it.strand.label == "wait") ? 0 : 1, Time.now - it.created_at] }
      .take(postgres_resource.target_standby_count) + [postgres_resource.representative_server]
    (postgres_resource.servers - servers_to_keep).each.each(&:incr_destroy)

    servers_to_keep.each(&:incr_configure)
    postgres_resource.incr_update_billing_records

    pop "postgres resource is converged"
  end

  def upgrade_candidate
    @upgrade_candidate ||= postgres_resource.upgrade_candidate_server
  end
end
