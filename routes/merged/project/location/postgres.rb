# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get api? do
      pg_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |pg_name, pg_ubid|
      if pg_name
        r.post true do
          pg_endpoint_helper.post(name: pg_name)
        end

        filter = {Sequel[:postgres_resource][:name] => pg_name}
      else
        filter = {Sequel[:postgres_resource][:id] => UBID.to_uuid(pg_ubid)}
      end

      filter[:location] = @location
      pg = @project.postgres_resources_dataset.first(filter)
      pg_endpoint_helper.instance_variable_set(:@resource, pg)

      unless pg
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      request.get true do
        pg_endpoint_helper.get
      end

      request.delete true do
        pg_endpoint_helper.delete
      end

      if web?
        request.post "restart" do
          Authorization.authorize(current_account.id, "Postgres:edit", pg.id)
          pg.servers.each do |s|
            s.incr_restart
          rescue Sequel::ForeignKeyConstraintViolation
          end
          request.redirect "#{@project.path}#{pg.path}"
        end
      end

      if api?
        request.post "failover" do
          pg_endpoint_helper.failover
        end
      end

      request.on "firewall-rule" do
        if api?
          request.get true do
            Authorization.authorize(current_account.id, "Postgres:Firewall:view", pg.id)
            Serializers::PostgresFirewallRule.serialize(pg.firewall_rules)
          end
        end

        request.post true do
          Authorization.authorize(current_account.id, "Postgres:Firewall:edit", pg.id)

          required_parameters = ["cidr"]
          request_body_params = Validation.validate_request_body(json_params, required_parameters)
          parsed_cidr = Validation.validate_cidr(request_body_params["cidr"])

          DB.transaction do
            PostgresFirewallRule.create_with_id(
              postgres_resource_id: pg.id,
              cidr: parsed_cidr.to_s
            )
            pg.incr_update_firewall_rules
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "Firewall rule is created"
            r.redirect "#{@project.path}#{pg.path}"
          end
        end

        request.is String do |firewall_rule_ubid|
          request.delete true do
            Authorization.authorize(current_account.id, "Postgres:Firewall:edit", pg.id)

            if (fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid))
              DB.transaction do
                fwr.destroy
                pg.incr_update_firewall_rules
              end
            end
            response.status = 204
            request.halt
          end
        end
      end

      request.on "metric-destination" do
        request.post true do
          Authorization.authorize(current_account.id, "Postgres:edit", pg.id)

          required_parameters = ["url", "username", "password"]
          request_body_params = Validation.validate_request_body(json_params, required_parameters)

          Validation.validate_url(request_body_params["url"])

          DB.transaction do
            PostgresMetricDestination.create_with_id(
              postgres_resource_id: pg.id,
              url: request_body_params["url"],
              username: request_body_params["username"],
              password: request_body_params["password"]
            )
            pg.servers.each(&:incr_configure_prometheus)
          end

          if api?
            Serializers::Postgres.serialize(pg, {detailed: true})
          else
            flash["notice"] = "Metric destination is created"
            request.redirect "#{@project.path}#{pg.path}"
          end
        end

        request.is String do |metric_destination_ubid|
          request.delete true do
            Authorization.authorize(current_account.id, "Postgres:edit", pg.id)

            if (md = PostgresMetricDestination.from_ubid(metric_destination_ubid))
              DB.transaction do
                md.destroy
                pg.servers.each(&:incr_configure_prometheus)
              end
            end

            response.status = 204
            request.halt
          end
        end
      end

      request.post "restore" do
        Authorization.authorize(current_account.id, "Postgres:create", @project.id)
        Authorization.authorize(current_account.id, "Postgres:view", pg.id)

        required_parameters = ["name", "restore_target"]
        request_body_params = Validation.validate_request_body(json_params, required_parameters)

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
          request.redirect "#{@project.path}#{st.subject.path}"
        end
      end

      request.post "reset-superuser-password" do
        pg_endpoint_helper.reset_superuser_password
      end
    end

    # 204 response for invalid names
    r.is String do |pg_name|
      r.post do
        pg_endpoint_helper.post(name: pg_name)
      end

      r.delete do
        response.status = 204
        nil
      end
    end
  end

  hash_branch(:api_project_location_prefix, "postgres", &branch)
  hash_branch(:project_location_prefix, "postgres", &branch)
end
