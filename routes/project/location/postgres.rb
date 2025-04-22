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

      next (r.delete? ? 204 : 404) unless pg

      r.get true do
        authorize("Postgres:view", pg.id)
        response.headers["Cache-Control"] = "no-store"

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
        pg.incr_destroy
        204
      end

      r.patch do
        authorize("Postgres:edit", pg.id)

        allowed_optional_parameters = ["size", "storage_size", "ha_type"]
        ignored_parameters = ["family"]
        request_body_params = validate_request_params([], allowed_optional_parameters, ignored_parameters)

        target_vm_size = Validation.validate_postgres_size(pg.location, request_body_params["size"] || pg.target_vm_size, @project.id)
        target_storage_size_gib = Validation.validate_postgres_storage_size(pg.location, target_vm_size.vm_size, request_body_params["storage_size"] || pg.target_storage_size_gib, @project.id)
        ha_type = request_body_params["ha_type"] || PostgresResource::HaType::NONE
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
          pg.read_replicas.map { _1.update(target_vm_size: target_vm_size.vm_size, target_storage_size_gib:) }
        end

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          flash["notice"] = "'#{pg.name}' will be updated according to requested configuration"
          response["Location"] = "#{@project.path}#{pg.path}"
          200
        end
      end

      r.post "restart" do
        authorize("Postgres:edit", pg.id)
        pg.servers.each do |s|
          s.incr_restart
        rescue Sequel::ForeignKeyConstraintViolation
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

          required_parameters = ["cidr"]
          request_body_params = validate_request_params(required_parameters)
          parsed_cidr = Validation.validate_cidr(request_body_params["cidr"])

          firewall_rule = DB.transaction do
            pg.incr_update_firewall_rules
            PostgresFirewallRule.create_with_id(
              postgres_resource_id: pg.id,
              cidr: parsed_cidr.to_s
            )
          end

          if api?
            Serializers::PostgresFirewallRule.serialize(firewall_rule)
          else
            flash["notice"] = "Firewall rule is created"
            r.redirect "#{@project.path}#{pg.path}"
          end
        end

        r.delete String do |firewall_rule_ubid|
          authorize("Postgres:edit", pg.id)

          if (fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid))
            DB.transaction do
              fwr.destroy
              pg.incr_update_firewall_rules
            end
          end
          204
        end
      end

      r.on "metric-destination" do
        r.post true do
          authorize("Postgres:edit", pg.id)

          password_param = (api? ? "password" : "metric-destination-password")
          required_parameters = ["url", "username", password_param]
          request_body_params = validate_request_params(required_parameters)

          Validation.validate_url(request_body_params["url"])

          DB.transaction do
            PostgresMetricDestination.create_with_id(
              postgres_resource_id: pg.id,
              url: request_body_params["url"],
              username: request_body_params["username"],
              password: request_body_params[password_param]
            )
            pg.servers.each(&:incr_configure_prometheus)
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "Metric destination is created"
            r.redirect "#{@project.path}#{pg.path}"
          end
        end

        r.delete String do |metric_destination_ubid|
          authorize("Postgres:edit", pg.id)

          if (md = PostgresMetricDestination.from_ubid(metric_destination_ubid))
            DB.transaction do
              md.destroy
              pg.servers.each(&:incr_configure_prometheus)
            end
          end

          204
        end
      end

      r.on "read-replica" do
        r.post true do
          required_parameters = ["name"]
          request_body_params = validate_request_params(required_parameters, [], [])
          st = Prog::Postgres::PostgresResourceNexus.assemble(
            project_id: @project.id,
            location_id: pg.location_id,
            name: request_body_params["name"],
            target_vm_size: pg.target_vm_size,
            target_storage_size_gib: pg.target_storage_size_gib,
            ha_type: PostgresResource::HaType::NONE,
            version: pg.version,
            flavor: pg.flavor,
            parent_id: pg.id,
            restore_target: nil
          )
          send_notification_mail_to_partners(st.subject, current_account.email)

          if api?
            Serializers::Postgres.serialize(st.subject, {detailed: true})
          else
            flash["notice"] = "'#{request_body_params["name"]}' will be ready in a few minutes"
            r.redirect "#{@project.path}#{st.subject.path}"
          end
        end
      end

      r.post "restore" do
        authorize("Postgres:create", @project.id)
        authorize("Postgres:view", pg.id)

        required_parameters = ["name", "restore_target"]
        request_body_params = validate_request_params(required_parameters)

        st = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: @project.id,
          location_id: pg.location_id,
          name: request_body_params["name"],
          target_vm_size: pg.target_vm_size,
          target_storage_size_gib: pg.target_storage_size_gib,
          version: pg.version,
          flavor: pg.flavor,
          parent_id: pg.id,
          restore_target: request_body_params["restore_target"]
        )
        send_notification_mail_to_partners(st.subject, current_account.email)

        if api?
          Serializers::Postgres.serialize(st.subject, {detailed: true})
        else
          flash["notice"] = "'#{request_body_params["name"]}' will be ready in a few minutes"
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

        required_parameters = api? ? ["password"] : ["password", "repeat_password"]
        request_body_params = validate_request_params(required_parameters)
        Validation.validate_postgres_superuser_password(request_body_params["password"], request_body_params["repeat_password"])

        DB.transaction do
          pg.update(superuser_password: request_body_params["password"])
          pg.representative_server.incr_update_superuser_password
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

        allowed_optional_parameters = ["maintenance_window_start_at"]
        request_body_params = validate_request_params([], allowed_optional_parameters)

        pg.update(maintenance_window_start_at: request_body_params["maintenance_window_start_at"])

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

        response.headers["Content-Disposition"] = "attachment; filename=\"#{pg.name}.pem\""
        response.headers["Content-Type"] = "application/x-pem-file"
        certs
      end
    end
  end
end
