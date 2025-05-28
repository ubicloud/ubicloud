# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.get api? do
      postgres_list
    end

    r.on POSTGRES_RESOURCE_NAME_OR_UBID do |pg_name, pg_ubid|
      if pg_name
        r.post api? do
          check_visible_location
          postgres_post(pg_name)
        end

        filter = {Sequel[:postgres_resource][:name] => pg_name}
      else
        filter = {Sequel[:postgres_resource][:id] => UBID.to_uuid(pg_ubid)}
      end

      filter[:location_id] = @location.id
      pg = @project.postgres_resources_dataset.first(filter)
      check_found_object(pg)

      r.get true do
        authorize("Postgres:view", pg.id)
        response.headers["cache-control"] = "no-store"

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          @pg = Serializers::Postgres.serialize(pg, {detailed: true, include_path: true})
          @family = Validation.validate_vm_size(pg.target_vm_size, "x64").family
          @option_tree, @option_parents = generate_postgres_configure_options(flavor: @pg[:flavor], location: @location)
          view "postgres/show"
        end
      end

      r.delete true do
        authorize("Postgres:delete", pg.id)
        DB.transaction do
          pg.incr_destroy
          audit_log(pg, "destroy")
        end
        204
      end

      r.patch true do
        authorize("Postgres:edit", pg.id)

        target_vm_size = Validation.validate_postgres_size(pg.location, typecast_params.str("size") || pg.target_vm_size, @project.id)
        target_storage_size_gib = Validation.validate_postgres_storage_size(pg.location, target_vm_size.vm_size, typecast_params.pos_int("storage_size") || pg.target_storage_size_gib, @project.id)
        ha_type = typecast_params.str("ha_type") || PostgresResource::HaType::NONE
        Validation.validate_postgres_ha_type(ha_type)

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

        current_postgres_vcpu_count = (PostgresResource::TARGET_STANDBY_COUNT_MAP[pg.ha_type] + 1) * pg.representative_server.vm.vcpus
        requested_postgres_vcpu_count = (PostgresResource::TARGET_STANDBY_COUNT_MAP[ha_type] + 1) * target_vm_size.vcpu
        Validation.validate_vcpu_quota(@project, "PostgresVCpu", requested_postgres_vcpu_count - current_postgres_vcpu_count)

        DB.transaction do
          pg.update(target_vm_size: target_vm_size.vm_size, target_storage_size_gib:, ha_type:)
          pg.read_replicas.map { it.update(target_vm_size: target_vm_size.vm_size, target_storage_size_gib:) }
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

      r.post "restart" do
        authorize("Postgres:edit", pg.id)
        DB.transaction do
          pg.servers.each do |s|
            s.incr_restart
          rescue Sequel::ForeignKeyConstraintViolation
          end
          audit_log(pg, "restart")
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "'#{pg.name}' will be restarted in a few seconds"
          r.redirect "#{@project.path}#{pg.path}"
        end
      end

      r.on "firewall-rule" do
        r.get api?, true do
          authorize("Postgres:view", pg.id)
          {
            items: Serializers::PostgresFirewallRule.serialize(pg.firewall_rules),
            count: pg.firewall_rules.count
          }
        end

        r.post true do
          authorize("Postgres:edit", pg.id)

          parsed_cidr = Validation.validate_cidr(typecast_params.nonempty_str!("cidr"))

          firewall_rule = nil
          DB.transaction do
            pg.incr_update_firewall_rules
            firewall_rule = PostgresFirewallRule.create_with_id(
              postgres_resource_id: pg.id,
              cidr: parsed_cidr.to_s,
              description: typecast_params.str("description")&.strip
            )
            audit_log(firewall_rule, "create", pg)
          end

          if api?
            Serializers::PostgresFirewallRule.serialize(firewall_rule)
          else
            flash["notice"] = "Firewall rule is created"
            r.redirect "#{@project.path}#{pg.path}"
          end
        end

        r.delete :ubid_uuid do |id|
          authorize("Postgres:edit", pg.id)

          if (fwr = pg.firewall_rules_dataset[id:])
            DB.transaction do
              fwr.destroy
              pg.incr_update_firewall_rules
              audit_log(fwr, "destroy")
            end
          end
          204
        end
      end

      r.on "metric-destination" do
        r.post true do
          authorize("Postgres:edit", pg.id)

          password_param = (api? ? "password" : "metric-destination-password")
          url, username, password = typecast_params.nonempty_str!(["url", "username", password_param])

          Validation.validate_url(url)

          DB.transaction do
            md = PostgresMetricDestination.create(postgres_resource_id: pg.id, url:, username:, password:)
            pg.servers.each(&:incr_configure_prometheus)
            audit_log(md, "create", pg)
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "Metric destination is created"
            r.redirect "#{@project.path}#{pg.path}"
          end
        end

        r.delete :ubid_uuid do |id|
          authorize("Postgres:edit", pg.id)

          if (md = pg.metric_destinations_dataset[id:])
            DB.transaction do
              md.destroy
              pg.servers.each(&:incr_configure_prometheus)
              audit_log(md, "destroy")
            end
          end

          204
        end
      end

      r.on "read-replica" do
        r.post true do
          authorize("Postgres:edit", pg.id)

          name = typecast_params.nonempty_str!("name")
          st = nil
          DB.transaction do
            st = Prog::Postgres::PostgresResourceNexus.assemble(
              project_id: @project.id,
              location_id: pg.location_id,
              name:,
              target_vm_size: pg.target_vm_size,
              target_storage_size_gib: pg.target_storage_size_gib,
              ha_type: PostgresResource::HaType::NONE,
              version: pg.version,
              flavor: pg.flavor,
              parent_id: pg.id,
              restore_target: nil
            )
            audit_log(pg, "create_replica", st.subject)
          end
          send_notification_mail_to_partners(st.subject, current_account.email)

          if api?
            Serializers::Postgres.serialize(st.subject, {detailed: true})
          else
            flash["notice"] = "'#{name}' will be ready in a few minutes"
            r.redirect "#{@project.path}#{st.subject.path}"
          end
        end
      end

      r.post "promote" do
        authorize("Postgres:edit", pg.id)

        unless pg.read_replica?
          error_msg = "Non read replica servers cannot be promoted."
          if api?
            fail CloverError.new(400, "InvalidRequest", error_msg)
          else
            flash["error"] = error_msg
            redirect_back_with_inputs
          end
        end

        DB.transaction do
          pg.incr_promote
          audit_log(pg, "promote")
        end

        if api?
          Serializers::Postgres.serialize(pg)
        else
          flash["notice"] = "'#{pg.name}' will be promoted in a few minutes, please refresh the page"
          r.redirect "#{@project.path}#{pg.path}"
        end
      end

      r.post "restore" do
        authorize("Postgres:create", @project.id)
        authorize("Postgres:view", pg.id)

        name, restore_target = typecast_params.nonempty_str!(["name", "restore_target"])
        st = nil

        DB.transaction do
          st = Prog::Postgres::PostgresResourceNexus.assemble(
            project_id: @project.id,
            location_id: pg.location_id,
            name:,
            target_vm_size: pg.target_vm_size,
            target_storage_size_gib: pg.target_storage_size_gib,
            version: pg.version,
            flavor: pg.flavor,
            parent_id: pg.id,
            restore_target:
          )
          audit_log(pg, "restore", st.subject)
        end
        send_notification_mail_to_partners(st.subject, current_account.email)

        if api?
          Serializers::Postgres.serialize(st.subject, {detailed: true})
        else
          flash["notice"] = "'#{name}' will be ready in a few minutes"
          r.redirect "#{@project.path}#{st.subject.path}"
        end
      end

      r.post "reset-superuser-password" do
        authorize("Postgres:view", pg.id)

        unless pg.representative_server.primary?
          if api?
            fail CloverError.new(400, "InvalidRequest", "Superuser password cannot be updated during restore!")
          else
            flash["error"] = "Superuser password cannot be updated during restore!"
            redirect_back_with_inputs
          end
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
          r.redirect "#{@project.path}#{pg.path}"
        end
      end

      r.post "set-maintenance-window" do
        authorize("Postgres:edit", pg.id)
        maintenance_window_start_at = typecast_params.pos_int("maintenance_window_start_at")

        DB.transaction do
          pg.update(maintenance_window_start_at:)
          audit_log(pg, "set_maintenance_window")
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "Maintenance window is set"
          r.redirect "#{@project.path}#{pg.path}"
        end
      end

      r.get "ca-certificates" do
        authorize("Postgres:view", pg.id)

        return 404 unless (certs = pg.ca_certificates)

        response.headers["content-disposition"] = "attachment; filename=\"#{pg.name}.pem\""
        response.headers["content-type"] = "application/x-pem-file"
        certs
      end

      r.get "metrics" do
        authorize("Postgres:view", pg.id)

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

        vmr = VictoriaMetricsResource.first(project_id: pg.representative_server.metrics_config[:project_id])
        vms = vmr&.servers&.first
        tsdb_client = vms&.client

        if tsdb_client.nil?
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
    end
  end
end
