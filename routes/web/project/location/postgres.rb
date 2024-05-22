# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.on String do |pg_name|
      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end
      @pg = Serializers::Common::Postgres.serialize(pg, {detailed: true, include_path: true})

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        view "postgres/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Postgres:delete", pg.id)
        pg.incr_destroy
        return {message: "Deleting #{pg.name}"}.to_json
      end

      r.on "firewall-rule" do
        r.post true do
          Authorization.authorize(@current_user.id, "Postgres:Firewall:edit", pg.id)
          parsed_cidr = Validation.validate_cidr(r.params["cidr"])

          DB.transaction do
            PostgresFirewallRule.create_with_id(
              postgres_resource_id: pg.id,
              cidr: parsed_cidr.to_s
            )
            pg.incr_update_firewall_rules
          end

          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{pg.path}"
        end

        r.is String do |firewall_rule_ubid|
          r.delete true do
            Authorization.authorize(@current_user.id, "Postgres:Firewall:edit", pg.id)
            fwr = PostgresFirewallRule.from_ubid(firewall_rule_ubid)
            unless fwr
              response.status = 404
              r.halt
            end

            DB.transaction do
              fwr.destroy
              pg.incr_update_firewall_rules
            end

            return {message: "Firewall rule deleted"}.to_json
          end
        end
      end

      r.post "restore" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        st = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: @project.id,
          location: pg.location,
          name: r.params["name"],
          target_vm_size: pg.target_vm_size,
          target_storage_size_gib: pg.target_storage_size_gib,
          parent_id: pg.id,
          restore_target: r.params["restore_target"]
        )

        flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

        r.redirect "#{@project.path}#{st.subject.path}"
      end

      r.post "reset-superuser-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        unless pg.representative_server.primary?
          flash["error"] = "Superuser password cannot be updated during restore!"
          return redirect_back_with_inputs
        end

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(superuser_password: r.params["original_password"])
        pg.representative_server.incr_update_superuser_password

        flash["notice"] = "The superuser password will be updated in a few seconds"

        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "restart" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.servers.each do |s|
          s.incr_restart
        rescue Sequel::ForeignKeyConstraintViolation
        end
        r.redirect "#{@project.path}#{pg.path}"
      end
    end
  end
end
