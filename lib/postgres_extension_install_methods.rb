# frozen_string_literal: true

# Per-server extension install machinery: walks postgres_server_extension
# rows, runs install scripts through daemonizer units, and applies their
# result files. Included into Prog::Postgres::PostgresServerNexus; relies on
# `postgres_server`, `resource`, and `vm` from the host prog.
module PostgresExtensionInstallMethods
  def process_extensions
    desired = resource.effective_desired_extensions
    existing_names = PostgresServerExtension.where(postgres_server_id: postgres_server.id).select_map(:name)
    (desired.keys - existing_names).each do |name|
      PostgresServerExtension.create(postgres_server_id: postgres_server.id, name:, state: "install_pending", last_transition_at: Time.now)
    end

    PostgresServerExtension.where(postgres_server_id: postgres_server.id).all.each do |row|
      version = desired[row.name]
      next if version.nil?

      # The extension is installed at a version that is no longer desired, so
      # redo the install. A verifying row may have an old post_restart unit in
      # flight, which is drained first so its status cannot be misread later.
      if PostgresServerExtension::INSTALLED_STATES.include?(row.state) && row.installed_version != version
        next if row.state == "verifying" && drain_extension_unit(extension_unit_name(row.name, "post_restart")).nil?
        row.update_state("install_pending", target_version: nil)
        next
      end

      case row.state
      when "install_pending"
        next if postgres_server.primary? && !resource.representative_install_unblocked?(row.name, version)

        vm.sshable.d_run(extension_unit_name(row.name, "install"), *extension_install_command(row.name, version, "install"))
        row.update_state("installing", target_version: version)
      when "installing"
        # Polling with target_version rather than the current desired version
        # records what was actually installed if desired changed mid-install.
        poll_extension_phase(row, row.target_version, "install")
      when "sync_pending"
        # The primary re-runs install when extension_config carries no entry at
        # the desired version, since rows only advance once it does.
        ext_version = resource.extension_config.dig(row.name, "!version")
        if postgres_server.primary? && ext_version != version
          vm.sshable.d_run(extension_unit_name(row.name, "install"), *extension_install_command(row.name, version, "install"))
          row.update_state("installing", target_version: version)
        end
      when "config_pending"
        # Every configure run writes all installed extensions' entries, so any
        # run after the bump that advanced this row put its entries on disk.
        row.update_state("ready") unless postgres_server.configure_set?
      when "verifying"
        poll_extension_phase(row, version, "post_restart") unless postgres_server.restart_set?
      end
      # restart_pending is not handled here; the convergence prog requests the
      # restart and drive_restart advances the row when it completes.
    end
  end

  def extension_unit_name(name, phase)
    "extension_#{name}_#{phase}"
  end

  def extension_server_role
    return "read_replica" if resource.read_replica?
    postgres_server.primary? ? "primary" : "standby"
  end

  def extension_install_command(name, version, phase)
    base_url = Config.postgres_extension_script_base_url
    script_path = "/tmp/extension-install-#{name}-#{phase}.sh"
    result_path = "/tmp/extension-result-#{name}-#{phase}.json"
    env_args = {
      "INSTALL_PHASE" => phase,
      "INSTALL_NAME" => name,
      "INSTALL_VERSION" => version,
      "INSTALL_PG_MAJOR" => postgres_server.version,
      "INSTALL_RESOURCE_ID" => resource.ubid,
      "INSTALL_SERVER_ID" => postgres_server.id,
      "INSTALL_SERVER_ROLE" => extension_server_role,
      "INSTALL_SERVER_FLAVOR" => resource.flavor,
      "INSTALL_SCRIPT_BASE_URL" => base_url,
      "INSTALL_RESULT_FILE" => result_path,
    }.map { |k, v| "#{k}=#{v}" }
    # The result file is removed before the script runs so a script that exits
    # without writing one cannot have a leftover from an earlier run accepted.
    payload = "set -e; rm -f '#{result_path}'; aws s3 cp '#{base_url}/#{name}/#{postgres_server.version}/install.sh' '#{script_path}' && bash '#{script_path}'"
    ["env", *env_args, "/bin/bash", "-c", payload]
  end

  def poll_extension_phase(row, version, phase)
    unit_name = extension_unit_name(row.name, phase)
    case drain_extension_unit(unit_name)
    when "NotStarted"
      vm.sshable.d_run(unit_name, *extension_install_command(row.name, version, phase))
    when "Failed"
      row.update_state("failed", last_error: "#{phase} d_run failed")
    when "Succeeded"
      apply_extension_result(row, version, phase)
    end
  end

  # Terminal status after cleaning the unit, "NotStarted", or nil while the
  # unit is in flight or in a transient substate (reported as Unknown) that
  # d_clean refuses; a persistent Unknown pages via the stall check.
  def drain_extension_unit(unit_name)
    case (status = vm.sshable.d_check(unit_name))
    when "Succeeded", "Failed"
      vm.sshable.d_clean(unit_name)
      status
    when "NotStarted"
      status
    end
  end

  # Keys starting with ! are driver bookkeeping added at publish time; a
  # script returning them would be writing into the driver's namespace.
  def malformed_extension_result?(result)
    !result.is_a?(Hash) ||
      !result["status"].is_a?(String) ||
      !(entries = result.fetch("config_entries", {})).is_a?(Hash) ||
      !entries.all? { |k, v| k.is_a?(String) && v.is_a?(String) && !k.start_with?("!") } ||
      ![true, false].include?(result.fetch("needs_restart", false))
  end

  def apply_extension_result(row, version, phase)
    result = JSON.parse(vm.sshable.cmd("cat /tmp/extension-result-:name_phase.json", name_phase: "#{row.name}-#{phase}"))
    if malformed_extension_result?(result)
      row.update_state("failed", last_error: "malformed result file for #{phase}")
      return
    end
    if result["status"] != "ok"
      row.update_state("failed", last_error: result["error"].to_s[0..200])
      return
    end

    if phase == "post_restart"
      row.update_state("ready")
      return
    end

    config_entries = result.fetch("config_entries", {})
    needs_restart = result.fetch("needs_restart", false)
    next_state = (config_entries.any? || needs_restart) ? "sync_pending" : "ready"
    DB.transaction do
      row.update_state(next_state, installed_version: version)
      if next_state == "sync_pending" && postgres_server.primary?
        # Locking this server's row serializes the publish with a takeover's
        # is_representative flip; whichever transaction commits second sees
        # the other's write.
        still_representative = PostgresServer.dataset.where(id: postgres_server.id).for_update.get(:is_representative)
        if still_representative
          entry = config_entries.merge("!needs_restart" => needs_restart, "!version" => version)
          resource.this.update(extension_config: Sequel.pg_jsonb_op(:extension_config).concat(Sequel.pg_jsonb(row.name => entry)))
          resource.reload
        end
      end
    end
  rescue JSON::ParserError, Sshable::SshError => e
    row.update_state("failed", last_error: "result file unreadable: #{e.message[0..200]}")
  end
end
