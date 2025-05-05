# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-location") do |r|
    r.get true do
      authorize("Location:view", @project.id)

      @dataset = @project.locations_dataset

      if api?
        result = @dataset.paginated_result(
          start_after: r.params["start_after"],
          page_size: r.params["page_size"],
          order_column: r.params["order_column"]
        )

        {
          items: Serializers::PrivateLocation.serialize(result[:records]),
          count: result[:count]
        }
      else
        @locations = @dataset.all
        view "private-location/index"
      end
    end

    r.post true do
      authorize("Location:create", @project.id)
      params = validate_request_params(["name", "provider_location_name", "access_key", "secret_key"])

      Validation.validate_name(params["name"])
      Validation.validate_provider_location_name("aws", params["provider_location_name"])

      loc = DB.transaction do
        loc = Location.create(
          display_name: params["name"],
          name: params["provider_location_name"],
          ui_name: params["name"],
          visible: true,
          provider: "aws",
          project_id: @project.id
        )
        LocationCredential.create(
          access_key: params["access_key"],
          secret_key: params["secret_key"]
        ) { it.id = loc.id }
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
        end

        204
      end

      r.post do
        authorize("Location:edit", @project.id)
        Validation.validate_name(r.params["name"])
        @location.update(ui_name: r.params["name"], display_name: r.params["name"])

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
