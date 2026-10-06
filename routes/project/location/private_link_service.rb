# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "private-link-service") do |r|
    next unless private_link_service_provider_enabled?(@location.provider)

    r.get api? do
      private_link_service_api_list
    end

    r.on PRIVATE_LINK_SERVICE_NAME_OR_UBID do |pls_name, pls_id|
      if pls_name
        r.post api? do
          check_visible_location
          private_link_service_api_post(pls_name)
        end

        filter = {Sequel[:private_link_service][:name] => pls_name}
      else
        filter = {Sequel[:private_link_service][:id] => pls_id}
      end

      filter[:location_id] = @location.id
      pls = @pls = @project.private_link_services_dataset.first(filter)
      check_found_object(pls)

      r.get true do
        authorize("PrivateLinkService:view", pls)
        if api?
          Serializers::PrivateLinkService.serialize(pls, {detailed: true})
        else
          r.redirect pls, "/overview"
        end
      end

      r.delete true do
        authorize("PrivateLinkService:delete", pls)
        DB.transaction do
          pls.incr_destroy
          audit_log(pls, "destroy")
        end

        if api?
          204
        else
          flash["notice"] = "Private link service '#{pls.name}' scheduled for deletion."
          r.redirect @project, "/private-link-service/#{@location.provider}"
        end
      end

      r.patch api? do
        private_link_service_api_patch(pls)
      end

      r.web do
        r.post "principals" do
          authorize("PrivateLinkService:edit", pls)
          handle_validation_failure("networking/private_link_service/show") { @page = "settings" }
          principals = private_link_service_principals_param

          DB.transaction do
            pls.update_allowed_principals(principals)
            audit_log(pls, "update")
          end

          flash["notice"] = "Allowed principals updated, they are being applied to the private link service."
          r.redirect pls, "/settings"
        end

        r.post "reconcile" do
          authorize("PrivateLinkService:edit", pls)
          DB.transaction do
            pls.incr_reconcile
            audit_log(pls, "update")
          end

          flash["notice"] = "The private link service is being reconciled and the private DNS record checked again."
          r.redirect pls, "/settings"
        end

        r.post "supported-regions" do
          authorize("PrivateLinkService:edit", pls)
          handle_validation_failure("networking/private_link_service/show") { @page = "settings" }
          regions = private_link_service_supported_regions_param(pls.private_subnet, typecast_params.array(:nonempty_str, "aws_supported_regions"))

          DB.transaction do
            pls.private_link_service_aws_resource.update_supported_regions(regions)
            audit_log(pls, "update")
          end

          flash["notice"] = "Supported regions updated, the private link service is being reconciled."
          r.redirect pls, "/settings"
        end

        r.post "attach-postgres" do
          authorize("PrivateLinkService:edit", pls)
          handle_validation_failure("networking/private_link_service/show") { @page = "postgres" }

          unless (pg = private_link_service_postgres_param(pls.private_subnet))
            fail Validation::ValidationFailed.new("postgres_resource_id" => "PostgreSQL resource not found in the selected private subnet")
          end

          DB.transaction do
            pls.attach_postgres_resource(pg)
            audit_log(pls, "update", pg)
          end

          flash["notice"] = "'#{pg.name}' attached, the private link service is being reconciled."
          r.redirect pls, "/postgres"
        end

        r.post "allowed-vpc-endpoints" do
          authorize("PrivateLinkService:edit", pls)
          handle_validation_failure("networking/private_link_service/show") { @page = "connections" }
          endpoints = private_link_service_vpc_endpoints_form_param

          DB.transaction do
            pls.private_link_service_aws_resource.update_allowed_endpoints(endpoints)
            audit_log(pls, "update")
          end

          flash["notice"] = "Approved endpoints updated, the connections are being reconciled."
          r.redirect pls, "/connections"
        end

        r.show_object(pls, actions: %w[overview postgres connections settings].freeze, perm: "PrivateLinkService:view", template: "networking/private_link_service/show")
      end
    end
  end
end
