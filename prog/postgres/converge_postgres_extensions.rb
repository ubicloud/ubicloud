# frozen_string_literal: true

class Prog::Postgres::ConvergePostgresExtensions < Prog::Base
  subject_is :postgres_resource

  label def start
    register_deadline(nil, 60 * 60)
    # Retry works by the resource strand destroying failed rows before budding
    # this prog; each server's process_extensions re-creates them.
    postgres_resource.cluster_servers.reject(&:primary?).each(&:incr_process_extensions)
    hop_watch
  end

  label def watch
    failed = postgres_resource.has_failed_extension_row?
    if failed
      Prog::PageNexus.assemble(
        "extension install failed on #{postgres_resource.ubid}",
        ["postgres_extension_failed", postgres_resource.id],
        postgres_resource.ubid, severity: "warning",
      )
    else
      Page.from_tag_parts("postgres_extension_failed", postgres_resource.id)&.incr_resolve
    end

    stalled = postgres_resource.has_stalled_extension_row?
    if stalled
      Prog::PageNexus.assemble(
        "extension convergence stuck on #{postgres_resource.ubid}",
        ["converge_postgres_extensions", postgres_resource.id],
        postgres_resource.ubid,
      )
    else
      Page.from_tag_parts("converge_postgres_extensions", postgres_resource.id)&.incr_resolve
    end

    restart_ids = postgres_resource.cluster_server_ids_needing_restart
    # Overbumping is safe: process_extensions no-ops when nothing is runnable.
    unconverged_ids = postgres_resource.cluster_servers.reject(&:extensions_converged?).map(&:id)
    already_pending = Semaphore.where(strand_id: unconverged_ids, name: "process_extensions").select_map(:strand_id)
    Semaphore.incr(unconverged_ids - already_pending, "process_extensions")

    already_restart_pending = Semaphore.where(strand_id: restart_ids, name: "restart").select_map(:strand_id)
    Semaphore.incr(restart_ids - already_restart_pending, "restart")

    advance_sync_pending_rows
    if unconverged_ids.empty?
      pop "postgres extensions are converged"
    elsif failed && !postgres_resource.has_active_extension_work?
      pop "extension install failed"
    end

    nap(stalled ? 30 : 5)
  end

  def advance_sync_pending_rows
    cluster_server_ids = postgres_resource.cluster_servers.map(&:id)
    extension_config = postgres_resource.effective_extension_config

    DB.transaction do
      advanced = false
      postgres_resource.effective_desired_extensions.each do |name, version|
        next unless extension_config.dig(name, "!version") == version
        rows = PostgresServerExtension.where(
          postgres_server_id: cluster_server_ids,
          name:,
          state: "sync_pending",
          installed_version: version,
        )
        next_state = extension_config.dig(name, "!needs_restart") ? "restart_pending" : "config_pending"
        advanced = true if rows.update(state: next_state, last_transition_at: Time.now) > 0
      end
      # Every configure run writes all installed extensions' entries, so any
      # configure starting after this commit covers the just-advanced rows.
      Semaphore.incr(cluster_server_ids, "configure") if advanced
    end
  end
end
