# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-location") do |r|
    r.is do
      r.get do
        authorize("Location:view", @project)

        @dataset = @project.locations_dataset

        if api?
          paginated_result(@dataset, Serializers::PrivateLocation)
        else
          @locations = @dataset.all
          view "private-location/index"
        end
      end

      r.post do
        authorize("Location:create", @project)
        handle_validation_failure("private-location/create")
        name, provider_location_name, access_key, secret_key = typecast_params.nonempty_str!(["name", "provider_location_name", "access_key", "secret_key"])

        Validation.validate_name(name)
        Validation.validate_provider_location_name("aws", provider_location_name)

        loc = nil
        DB.transaction do
          loc = Location.create(
            display_name: name,
            name: provider_location_name,
            ui_name: name,
            visible: true,
            provider: "aws",
            project_id: @project.id,
            byoc: true
          )
          LocationCredential.create_with_id(loc, access_key:, secret_key:)
          audit_log(loc, "create")
        end

        if api?
          Serializers::PrivateLocation.serialize(loc)
        else
          r.redirect loc
        end
      end
    end

    r.get(web?, "create") do
      authorize("Location:create", @project)
      view "private-location/create"
    end

    r.is String do |name|
      @location = @project.locations.find { |loc| loc.ui_name == name }
      check_found_object(@location)

      r.get do
        authorize("Location:view", @project)

        if api?
          Serializers::PrivateLocation.serialize(@location)
        else
          view "private-location/show"
        end
      end

      r.delete do
        authorize("Location:delete", @project)

        if @location.has_resources?
          fail DependencyError.new("Private location '#{@location.ui_name}' has some resources, first, delete them.")
        end

        DB.transaction do
          @location.location_credential.destroy
          @location.destroy
          audit_log(@location, "destroy")
        end

        204
      end

      r.post do
        authorize("Location:edit", @project)
        name = typecast_params.nonempty_str("name")
        Validation.validate_name(name)

        DB.transaction do
          @location.update(ui_name: name, display_name: name)
          audit_log(@location, "update")
        end

        if api?
          Serializers::PrivateLocation.serialize(@location)
        else
          flash["notice"] = "The location name is updated to '#{@location.ui_name}'."
          r.redirect @location
        end
      end
    end
  end
end
