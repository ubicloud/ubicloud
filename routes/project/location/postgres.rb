# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.get api? do
      postgres_list
    end

    r.on POSTGRES_RESOURCE_NAME_OR_UBID do |pg_name, pg_id|
      if pg_name
        r.post api? do
          check_visible_location
          postgres_post(pg_name)
        end

        filter = {Sequel[:postgres_resource][:name] => pg_name}
      else
        filter = {Sequel[:postgres_resource][:id] => pg_id}
      end

      filter[:location_id] = @location.id
      @pg = pg = @project.postgres_resources_dataset.first(filter)
      check_found_object(pg)

      r.is do
        r.get do
          authorize("Postgres:view", pg)

          if api?
            response.headers["cache-control"] = "no-store"
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            r.redirect pg, "/overview"
          end
        end

        r.delete do
          authorize("Postgres:delete", pg)
          DB.transaction do
            pg.incr_destroy
            audit_log(pg, "destroy")
          end
          204
        end

        r.patch do
          authorize("Postgres:edit", pg)

          size = typecast_params.nonempty_str("size", pg.target_vm_size)
          target_storage_size_gib = typecast_params.pos_int("storage_size", pg.target_storage_size_gib)
          ha_type = typecast_params.nonempty_str("ha_type", pg.ha_type)
          tags = typecast_params.array(:Hash, "tags", pg.tags)

          postgres_params = {
            "flavor" => pg.flavor,
            "location" => pg.location,
            "family" => Option::POSTGRES_SIZE_OPTIONS[size]&.family,
            "size" => size,
            "storage_size" => target_storage_size_gib,
            "ha_type" => ha_type,
            "version" => pg.version
          }

          validate_postgres_input(pg.name, postgres_params)

          if pg.representative_server.nil? || target_storage_size_gib < pg.representative_server.storage_size_gib
            begin
              current_disk_usage = pg.representative_server.vm.sshable.cmd("df --output=used /dev/vdb | tail -n 1").strip.to_i / (1024 * 1024)
            rescue
              fail CloverError.new(400, "InvalidRequest", "Database is not ready for update", {})
            end

            if target_storage_size_gib * 0.8 < current_disk_usage
              fail Validation::ValidationFailed.new({storage_size: "Insufficient storage size is requested. It is only possible to reduce the storage size if the current usage is less than 80% of the requested size."})
            end
          end

          current_parsed_size = Option::POSTGRES_SIZE_OPTIONS[pg.target_vm_size]
          current_postgres_vcpu_count = pg.target_server_count * current_parsed_size.vcpu_count

          requested_parsed_size = Option::POSTGRES_SIZE_OPTIONS[postgres_params["size"]]
          requested_standby_count = Option::POSTGRES_HA_OPTIONS[postgres_params["ha_type"]].standby_count
          requested_postgres_vcpu_count = (requested_standby_count + 1) * requested_parsed_size.vcpu_count

          Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count - current_postgres_vcpu_count)

          DB.transaction do
            pg.update(target_vm_size: requested_parsed_size.name, target_storage_size_gib:, ha_type:, tags:)
            pg.read_replicas_dataset.update(target_vm_size: requested_parsed_size.name, target_storage_size_gib:)
            audit_log(pg, "update")
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "'#{pg.name}' will be updated according to requested configuration"
            response["location"] = "#{@project.path}#{pg.path}"
            200
          end
        end
      end

      r.rename pg, perm: "Postgres:edit", serializer: Serializers::Postgres, template_prefix: "postgres" do
        pg.incr_refresh_dns_record
        pg.incr_refresh_certificates
      end

      show_actions = if pg.read_replica?
        %w[overview connection charts networking config settings]
      else
        %w[overview connection charts networking resize high-availability read-replica backup-restore config upgrade settings]
      end
      r.show_object(pg, actions: show_actions, perm: "Postgres:view", template: "postgres/show")

      r.post "restart" do
        authorize("Postgres:edit", pg)
        DB.transaction do
          pg.incr_restart
          audit_log(pg, "restart")
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "'#{pg.name}' will be restarted in a few seconds"
          r.redirect pg, "/settings"
        end
      end

      r.on api?, "firewall-rule" do
        r.is do
          r.get do
            authorize("Postgres:view", pg)
            firewall = postgres_require_customer_firewall!
            rules = pg.pg_firewall_rules(firewall:)

            {
              items: Serializers::PostgresFirewallRule.serialize(rules),
              count: rules.count
            }
          end

          r.post do
            authorize("Postgres:edit", pg)
            fw = postgres_require_customer_firewall!

            parsed_cidr = Validation.validate_cidr(typecast_params.nonempty_str!("cidr")).to_s
            description = typecast_params.str("description")&.strip

            firewall_rule = nil
            DB.transaction do
              firewall_rule = fw.insert_firewall_rule(parsed_cidr, Sequel.pg_range(5432..5432), description:)
              audit_log(firewall_rule, "create", [fw, pg])

              firewall_rule2 = fw.insert_firewall_rule(parsed_cidr, Sequel.pg_range(6432..6432), description:)
              audit_log(firewall_rule2, "create", [fw, pg])
            end

            Serializers::PostgresFirewallRule.serialize(firewall_rule)
          end
        end

        r.is :ubid_uuid do |id|
          authorize("Postgres:edit", pg)
          firewall = postgres_require_customer_firewall!
          fwr = pg.pg_firewall_rule(id, firewall:)
          check_found_object(fwr)

          r.patch do
            current_cidr = fwr.cidr.to_s
            new_cidr = Validation.validate_cidr(typecast_params.nonempty_str("cidr") || fwr.cidr.to_s).to_s
            description = typecast_params.str("description")&.strip || fwr.description

            DB.transaction do
              fwr.update(
                cidr: new_cidr,
                description:
              )
              firewall.update_private_subnet_firewall_rules if current_cidr != new_cidr
              audit_log(fwr, "update")
            end

            Serializers::PostgresFirewallRule.serialize(fwr)
          end

          r.delete do
            DB.transaction do
              fwr.destroy
              firewall.update_private_subnet_firewall_rules
              audit_log(fwr, "destroy")
            end

            204
          end
        end
      end

      r.on "metric-destination" do
        r.post true do
          authorize("Postgres:edit", pg)
          handle_validation_failure("postgres/show") { @page = "charts" }

          password_param = (api? ? "password" : "metric-destination-password")
          url, username, password = typecast_params.nonempty_str!(["url", "username", password_param])

          Validation.validate_url(url)

          DB.transaction do
            md = PostgresMetricDestination.create(postgres_resource_id: pg.id, url:, username:, password:)
            pg.servers.each(&:incr_configure_metrics)
            audit_log(md, "create", pg)
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "Metric destination is created"
            r.redirect pg, "/charts"
          end
        end

        r.delete :ubid_uuid do |id|
          authorize("Postgres:edit", pg)

          if (md = pg.metric_destinations_dataset[id:])
            DB.transaction do
              md.destroy
              pg.servers.each(&:incr_configure_metrics)
              audit_log(md, "destroy")
            end
          end

          204
        end
      end

      r.post "read-replica" do
        authorize("Postgres:edit", pg)
        handle_validation_failure("postgres/show") { @page = "read-replica" }

        name = typecast_params.nonempty_str!("name")

        Validation.validate_name(name)

        Validation.validate_vcpu_quota(@project, "PostgresVCpu", Option::POSTGRES_SIZE_OPTIONS[pg.target_vm_size].vcpu_count)
        unless pg.ready_for_read_replica?
          error_msg = "Parent server is not ready for read replicas. There are no backups, yet."
          fail CloverError.new(400, "InvalidRequest", error_msg)
        end

        replica = nil
        DB.transaction do
          replica = Prog::Postgres::PostgresResourceNexus.assemble(
            project_id: @project.id,
            location_id: pg.location_id,
            name:,
            target_vm_size: pg.target_vm_size,
            target_storage_size_gib: pg.target_storage_size_gib,
            ha_type: PostgresResource::HaType::NONE,
            target_version: pg.version,
            flavor: pg.flavor,
            parent_id: pg.id,
            restore_target: nil
          ).subject
          audit_log(pg, "create_replica", replica)
        end
        send_notification_mail_to_partners(replica, current_account.email)

        if api?
          Serializers::Postgres.serialize(replica, {detailed: true})
        else
          flash["notice"] = "'#{name}' will be ready in a few minutes"
          r.redirect replica, "/overview"
        end
      end

      r.post "promote" do
        authorize("Postgres:edit", pg)
        handle_validation_failure("postgres/show") { @page = "settings" }

        unless pg.read_replica?
          error_msg = "Non read replica servers cannot be promoted."
          fail CloverError.new(400, "InvalidRequest", error_msg)
        end

        DB.transaction do
          pg.incr_promote
          audit_log(pg, "promote")
        end

        if api?
          Serializers::Postgres.serialize(pg)
        else
          flash["notice"] = "'#{pg.name}' will be promoted in a few minutes, please refresh the page"
          r.redirect pg, "/settings"
        end
      end

      r.post "restore" do
        authorize("Postgres:create", @project)
        authorize("Postgres:view", pg)
        handle_validation_failure("postgres/show") { @page = "backup_restore" }

        name, restore_target = typecast_params.nonempty_str!(["name", "restore_target"])

        Validation.validate_name(name)

        Validation.validate_vcpu_quota(@project, "PostgresVCpu", Option::POSTGRES_SIZE_OPTIONS[pg.target_vm_size].vcpu_count)

        restored = nil
        DB.transaction do
          restored = Prog::Postgres::PostgresResourceNexus.assemble(
            project_id: @project.id,
            location_id: pg.location_id,
            name:,
            target_vm_size: pg.target_vm_size,
            target_storage_size_gib: pg.target_storage_size_gib,
            target_version: pg.version,
            flavor: pg.flavor,
            parent_id: pg.id,
            restore_target:
          ).subject
          audit_log(pg, "restore", restored)
        end
        send_notification_mail_to_partners(restored, current_account.email)

        if api?
          Serializers::Postgres.serialize(restored, {detailed: true})
        else
          flash["notice"] = "'#{name}' will be ready in a few minutes"
          r.redirect restored, "/overview"
        end
      end

      r.post "reset-superuser-password" do
        authorize("Postgres:view", pg)
        handle_validation_failure("postgres/show") { @page = "settings" }

        if pg.read_replica?
          raise CloverError.new(400, "InvalidRequest", "Superuser password cannot be updated for read replicas!")
        end

        password = typecast_params.str!("password")
        repeat_password = typecast_params.str!("repeat_password") if web?
        Validation.validate_postgres_superuser_password(password, repeat_password)

        DB.transaction do
          pg.update(superuser_password: password)
          pg.representative_server.incr_update_superuser_password
          audit_log(pg, "reset_superuser_password")
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "The superuser password will be updated in a few seconds"
          r.redirect pg, "/settings"
        end
      end

      r.post "set-maintenance-window" do
        authorize("Postgres:edit", pg)
        maintenance_window_start_at = typecast_params.int("maintenance_window_start_at")

        DB.transaction do
          pg.update(maintenance_window_start_at:)
          audit_log(pg, "set_maintenance_window")
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "Maintenance window is set"
          r.redirect pg, "/settings"
        end
      end

      r.get "ca-certificates" do
        authorize("Postgres:view", pg)

        next unless (certs = pg.ca_certificates)

        response.headers["content-disposition"] = "attachment; filename=\"#{pg.name}.pem\""
        response.content_type = :pem
        certs
      end

      r.get api?, "backup" do
        authorize("Postgres:view", pg)

        backups = pg.timeline.backups.map do |backup|
          {
            key: backup.key,
            last_modified: backup.last_modified.utc.iso8601
          }
        end

        {
          items: backups,
          count: backups.count
        }
      end

      r.get "metrics", r.accepts_json? do
        authorize("Postgres:view", pg)

        start_time, end_time = typecast_params.str(%w[start end])
        start_time ||= (DateTime.now.new_offset(0) - 30.0 / 1440).rfc3339
        start_time = Validation.validate_rfc3339_datetime_str(start_time, "start")

        end_time ||= DateTime.now.new_offset(0).rfc3339
        end_time = Validation.validate_rfc3339_datetime_str(end_time, "end")

        start_ts = start_time.to_i
        end_ts = end_time.to_i

        if end_ts < start_ts
          raise CloverError.new(400, "InvalidRequest", "End timestamp must be greater than start timestamp")
        end

        if end_ts - start_ts > 31 * 24 * 60 * 60 + 5 * 60
          raise CloverError.new(400, "InvalidRequest", "Maximum time range is 31 days")
        end

        if start_ts < Time.now.utc.to_i - 31 * 24 * 60 * 60
          raise CloverError.new(400, "InvalidRequest", "Cannot query metrics older than 31 days")
        end

        metric_key = typecast_params.str("key")&.to_sym
        single_query = !metric_key.nil?

        if single_query && !Metrics::POSTGRES_METRICS.key?(metric_key)
          raise CloverError.new(400, "InvalidRequest", "Invalid metric name")
        end

        metric_keys = metric_key ? [metric_key] : Metrics::POSTGRES_METRICS.keys

        unless (tsdb_client = PostgresServer.victoria_metrics_client)
          raise CloverError.new(404, "NotFound", "Metrics are not configured for this instance")
        end

        results = metric_keys.map do |key|
          metric_definition = Metrics::POSTGRES_METRICS[key]

          series_results = metric_definition.series.filter_map do |s|
            query = s.query.gsub("$ubicloud_resource_id", pg.ubid)
            begin
              series_query_result = tsdb_client.query_range(
                query: query,
                start_ts: start_ts,
                end_ts: end_ts
              )

              # This can be a two cases:
              # 1. Missing data (e.g. no data for the given time range)
              # 2. No data for the given query (maybe bad query)
              if series_query_result.empty?
                next
              end

              # Combine labels with configured series labesls.
              series_query_result.each { it["labels"].merge!(s.labels) }

              series_query_result
            rescue VictoriaMetrics::ClientError => e
              Clog.emit("Could not query VictoriaMetrics") { {error: e.message, query: query} }

              if single_query
                raise CloverError.new(500, "InternalError", "Internal error while querying metrics", {query: query})
              end
            end
          end

          {
            key: key.to_s,
            name: metric_definition.name,
            unit: metric_definition.unit,
            description: metric_definition.description,
            series: series_results.flatten
          }
        end

        {
          metrics: results
        }
      end

      r.is "config" do
        r.get do
          authorize("Postgres:view", pg)

          {
            pg_config: pg.user_config,
            pgbouncer_config: pg.pgbouncer_user_config
          }
        end

        r.on method: [:post, :patch] do
          authorize("Postgres:edit", pg)
          handle_validation_failure("postgres/show") { @page = "config" }

          if web?
            pg_keys = typecast_params.array(:str, "pg_config_keys") || []
            pg_values = typecast_params.array(:str, "pg_config_values") || []
            pg_config = config_hash_from_kvs(pg_keys, pg_values)

            pgbouncer_keys = typecast_params.array(:str, "pgbouncer_config_keys") || []
            pgbouncer_values = typecast_params.array(:str, "pgbouncer_config_values") || []
            pgbouncer_config = config_hash_from_kvs(pgbouncer_keys, pgbouncer_values)
          elsif r.patch?
            pg_config = typecast_params.Hash("pg_config") || {}
            pgbouncer_config = typecast_params.Hash("pgbouncer_config") || {}
            # For PATCH requests, merge with existing config
            pg_config = pg.user_config.merge(pg_config).compact
            pgbouncer_config = pg.pgbouncer_user_config.merge(pgbouncer_config).compact
          else
            pg_config = typecast_params.Hash!("pg_config")
            pgbouncer_config = typecast_params.Hash!("pgbouncer_config")
          end

          pg_validator = Validation::PostgresConfigValidator.new(pg.version)
          pg_errors = pg_validator.validation_errors(pg_config)

          pgbouncer_validator = Validation::PostgresConfigValidator.new("pgbouncer")
          pgbouncer_errors = pgbouncer_validator.validation_errors(pgbouncer_config)

          if pg_errors.any? || pgbouncer_errors.any?
            pg_errors = pg_errors.transform_keys { |key| "pg_config.#{key}" }
            pgbouncer_errors = pgbouncer_errors.transform_keys { |key| "pgbouncer_config.#{key}" }
            raise Validation::ValidationFailed.new(pg_errors.merge(pgbouncer_errors))
          end

          pg.update(user_config: pg_config, pgbouncer_user_config: pgbouncer_config)

          pg.servers.each(&:incr_configure)

          audit_log(pg, "update")

          if api?
            {
              pg_config: pg.user_config,
              pgbouncer_config: pg.pgbouncer_user_config
            }
          else
            flash["notice"] = "Configuration updated successfully"
            r.redirect pg, "/config"
          end
        end
      end

      r.is "upgrade" do
        r.get api? do
          # api-only route, web GET upgrade route handled by r.show_object call earlier in route
          authorize("Postgres:view", pg.id)

          if pg.target_version == pg.version
            raise CloverError.new(400, "InvalidRequest", "Database is not upgrading")
          end

          Serializers::PostgresUpgrade.serialize(pg)
        end

        r.post do
          authorize("Postgres:edit", pg.id)

          Validation.validate_postgres_upgrade(pg)

          DB.transaction do
            pg.update(target_version: pg.version.to_i + 1)
            pg.read_replicas_dataset.update(target_version: pg.target_version)
            audit_log(pg, "upgrade")
          end

          if api?
            Serializers::PostgresUpgrade.serialize(pg)
          else
            flash["notice"] = "Database upgrade started successfully"
            r.redirect pg, "/upgrade"
          end
        end
      end
    end
  end
end
