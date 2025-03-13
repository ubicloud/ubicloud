# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::ConvergePostgresResource < Prog::Base
  subject_is :postgres_resource

  label def provision_servers
    hop_wait_servers_to_be_ready if postgres_resource.has_enough_fresh_servers?

    if postgres_resource.servers.none? { _1.vm.vm_host.nil? }
      exclude_host_ids = (Config.development? || Config.is_e2e) ? [] : postgres_resource.servers.map { _1.vm.vm_host.id }
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
    if postgres_resource.representative_server
      hop_prune_servers unless postgres_resource.representative_server.needs_recycling?
      postgres_resource.representative_server.trigger_failover
    end

    nap 60
  end

  label def prune_servers
    servers_to_keep = postgres_resource.servers
      .reject { _1.representative_at || _1.needs_recycling? }
      .sort_by { [(_1.strand.label == "wait") ? 0 : 1, Time.now - _1.created_at] }
      .take(postgres_resource.target_standby_count) + [postgres_resource.representative_server]
    (postgres_resource.servers - servers_to_keep).each { _1.incr_destroy }

    pop "postgres resource is converged"
  end
end
