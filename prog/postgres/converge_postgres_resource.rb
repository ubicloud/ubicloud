# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Postgres::ConvergePostgresResource < Prog::Base
  subject_is :postgres_resource

  label def start
    register_deadline("recycle_representative_server", 2 * 60 * 60)
    hop_provision_servers
  end

  label def provision_servers
    hop_wait_servers_to_be_ready if postgres_resource.has_enough_fresh_servers?

    if postgres_resource.servers.all? { it.vm.vm_host } || postgres_resource.location.aws?
      exclude_host_ids = []
      if !(Config.development? || Config.is_e2e) && postgres_resource.location.provider == HostProvider::HETZNER_PROVIDER_NAME
        used_data_centers = postgres_resource.servers.map { it.vm.vm_host.data_center }.uniq
        exclude_host_ids = VmHost.where(data_center: used_data_centers).map(&:id)
      end
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id, timeline_access: "fetch", exclude_host_ids: exclude_host_ids)
    end

    nap 5
  end

  label def wait_servers_to_be_ready
    hop_provision_servers unless postgres_resource.has_enough_fresh_servers?

    hop_recycle_representative_server if postgres_resource.has_enough_ready_servers?

    nap 60
  end

  label def recycle_representative_server
    if (rs = postgres_resource.representative_server) && !postgres_resource.ongoing_failover?
      hop_prune_servers unless rs.needs_recycling?
      hop_provision_servers unless postgres_resource.has_enough_ready_servers?

      nap 10 * 60 unless postgres_resource.in_maintenance_window?

      register_deadline(nil, 10 * 60)
      rs.trigger_failover(mode: "planned")
    end

    nap 60
  end

  label def prune_servers
    # Below we only keep servers that does not need recycling. If there are
    # more such servers than required, we prefer ready and recent servers (in that order)
    servers_to_keep = postgres_resource.servers
      .reject { it.representative_at || it.needs_recycling? }
      .sort_by { [(it.strand.label == "wait") ? 0 : 1, Time.now - it.created_at] }
      .take(postgres_resource.target_standby_count) + [postgres_resource.representative_server]
    (postgres_resource.servers - servers_to_keep).each.each(&:incr_destroy)

    servers_to_keep.each(&:incr_configure)
    postgres_resource.incr_update_billing_records

    pop "postgres resource is converged"
  end
end
