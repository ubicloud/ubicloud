# frozen_string_literal: true

# Predicates and ID-set queries that drive the postgres extension lifecycle.
# Included into PostgresResource; relies on `representative_server`,
# `read_replica?`, `parent`, `servers`, and `read_replicas` from the host class.
module PostgresExtensionOrchestrationMethods
  def effective_desired_extensions
    read_replica? ? parent.desired_extensions : desired_extensions
  end

  def effective_extension_config
    read_replica? ? parent.extension_config : extension_config
  end

  def cluster_servers
    servers + read_replicas.flat_map(&:servers)
  end

  def needs_extension_convergence?
    !desired_extensions.empty? && !cluster_servers.all?(&:extensions_converged?) && !has_failed_extension_row?
  end

  def has_stalled_extension_row?
    desired_extension_rows.where(state: PostgresServerExtension::ACTIVE_STATES).where { last_transition_at < Time.now - 10 * 60 }.any?
  end

  def has_failed_extension_row?
    desired_extension_rows.where(state: "failed").any?
  end

  def has_active_extension_work?
    desired_extension_rows.where(state: PostgresServerExtension::ACTIVE_STATES).any?
  end

  private def desired_extension_rows
    PostgresServerExtension.where(postgres_server_id: cluster_servers.map(&:id), name: effective_desired_extensions.keys)
  end

  def representative_install_unblocked?(name, version)
    representative_id = representative_server.id
    representative_row = PostgresServerExtension.where(postgres_server_id: representative_id, name:).first
    return false if representative_row && representative_row.state != "install_pending"

    peer_ids = cluster_servers.reject { |s| s.id == representative_id }.map(&:id)
    return true if peer_ids.empty?
    PostgresServerExtension.where(
      postgres_server_id: peer_ids,
      name:,
      installed_version: version,
      state: PostgresServerExtension::INSTALLED_STATES,
    ).count == peer_ids.size
  end

  def restart_unblocked?(server_id, name, version)
    # A read replica's representative is itself; check the parent's cluster.
    return parent.restart_unblocked?(server_id, name, version) if read_replica?

    representative_id = representative_server.id
    if server_id == representative_id
      standby_ids = servers.reject { |s| s.id == representative_id }.map(&:id)
      return true if standby_ids.empty?
      PostgresServerExtension.where(
        postgres_server_id: standby_ids,
        name:,
        installed_version: version,
        state: "ready",
      ).count == standby_ids.size
    else
      representative_row = PostgresServerExtension.where(postgres_server_id: representative_id, name:).first
      representative_row && %w[restart_pending verifying ready].include?(representative_row.state) && representative_row.installed_version == version
    end
  end

  # At most one server restarts at a time, preserving failover capacity and,
  # on synchronous clusters, write availability.
  def cluster_server_ids_needing_restart
    PostgresServerExtension.where(
      postgres_server_id: cluster_servers.map(&:id),
      state: "restart_pending",
    ).all.filter_map do |row|
      version = effective_desired_extensions[row.name]
      next unless version && row.installed_version == version
      row.postgres_server_id if restart_unblocked?(row.postgres_server_id, row.name, version)
    end.uniq.take(1)
  end
end
