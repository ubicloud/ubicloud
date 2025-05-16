# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-location") do |r|
    r.get true do
      authorize("Location:view", @project.id)

      @dataset = @project.locations_dataset

      if api?
        paginated_result(@dataset, Serializers::PrivateLocation)
      else
        @locations = @dataset.all
        view "private-location/index"
      end
    end

    r.post true do
      authorize("Location:create", @project.id)
      check_required_web_params(["name", "provider_location_name", "access_key", "secret_key"])

      tp = typecast_params
      name = tp.nonempty_str("name")
      provider_location_name = tp.nonempty_str("provider_location_name")
      Validation.validate_name(name)
      Validation.validate_provider_location_name("aws", provider_location_name)

      loc = DB.transaction do
        loc = Location.create(
          display_name: name,
          name: provider_location_name,
          ui_name: name,
          visible: true,
          provider: "aws",
          project_id: @project.id
        )
        LocationCredential.create(
          access_key: tp.nonempty_str("access_key"),
          secret_key: tp.nonempty_str("secret_key")
        ) { it.id = loc.id }
        audit_log(loc, "create")
        loc
      end

      if api?
        Serializers::PrivateLocation.serialize(loc)
      else
        r.redirect "#{@project.path}#{loc.path}"
      end
    end

    r.get(web?, "create") do
      authorize("Location:create", @project.id)

      options = OptionTreeGenerator.new
      options.add_option(name: "name")
      options.add_option(name: "provider_location_name", values: Option::AWS_LOCATIONS.map { |l| {value: l, display_name: l} })
      options.add_option(name: "access_key")
      options.add_option(name: "secret_key")
      @option_tree, @option_parents = options.serialize

      view "private-location/create"
    end

    r.is String do |name|
      @location = @project.locations.find { |loc| loc.ui_name == name }
      check_found_object(@location)

      r.get do
        authorize("Location:view", @project.id)

        if api?
          Serializers::PrivateLocation.serialize(@location)
        else
          view "private-location/show"
        end
      end

      r.delete do
        authorize("Location:delete", @project.id)

        if @location.has_resources
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
        authorize("Location:edit", @project.id)
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
          r.redirect "#{@project.path}#{@location.path}"
        end
      end
    end
  end
end
