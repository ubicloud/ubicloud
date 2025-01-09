# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.get api? do
      postgres_list
    end

    r.on NAME_OR_UBID do |pg_name, pg_ubid|
      if pg_name
        r.post api? do
          postgres_post(pg_name)
        end

        filter = {Sequel[:postgres_resource][:name] => pg_name}
      else
        filter = {Sequel[:postgres_resource][:id] => UBID.to_uuid(pg_ubid)}
      end

      filter[:location] = @location
      pg = @project.postgres_resources_dataset.first(filter)

      next (r.delete? ? 204 : 404) unless pg

      r.get true do
        authorize("Postgres:view", pg.id)
        response.headers["Cache-Control"] = "no-store"

        if api?
          Serializers::Postgres.serialize(pg, {detailed: true})
        else
          @pg = Serializers::Postgres.serialize(pg, {detailed: true, include_path: true})
          view "postgres/show"
        end
      end

      r.delete true do
        authorize("Postgres:delete", pg.id)
        pg.incr_destroy
        204
      end

      r.post web?, "restart" do
        authorize("Postgres:edit", pg.id)
        pg.servers.each do |s|
          s.incr_restart
        rescue Sequel::ForeignKeyConstraintViolation
        end
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post api?, "failover" do
        authorize("Postgres:view", pg.id)

        unless pg.representative_server.primary?
          fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered during restore!")
        end

        unless @project.get_ff_postgresql_base_image
          fail CloverError.new(400, "InvalidRequest", "Failover cannot be triggered for this resource!")
        end

        unless pg.representative_server.trigger_failover
          fail CloverError.new(400, "InvalidRequest", "There is not a suitable standby server to failover!")
        end

        Serializers::Postgres.serialize(pg, {detailed: true})
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
            Serializers::PostgresFirewallRule.serialize(firewall_rule, {detailed: true})
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

      r.post "restore" do
        authorize("Postgres:create", @project.id)
        authorize("Postgres:view", pg.id)

        required_parameters = ["name", "restore_target"]
        request_body_params = validate_request_params(required_parameters)

        st = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: @project.id,
          location: pg.location,
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
    end

    # 204 response for invalid names
    r.is String do |pg_name|
      r.post do
        postgres_post(pg_name)
      end

      r.delete do
        204
      end
    end
  end
end
