# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "aws-region") do |r|
    r.get true do
      @regions = @project.aws_location_credentials

      if api?
        Serializers::AwsRegion.serialize(@regions)
      else
        view "aws-region/index"
      end
    end

    r.post true do
      authorize("AwsLocationCredential:create", @project.id)
      required_parameters = ["name", "aws_region_name", "aws_access_key", "aws_secret_key"]
      request_body_params = validate_request_params(required_parameters)

      Validation.validate_name(request_body_params["name"])
      Validation.validate_aws_region_name(request_body_params["aws_region_name"])

      loc = DB.transaction do
        alc = AwsLocationCredential.create_with_id(
          access_key: request_body_params["aws_access_key"],
          secret_key: request_body_params["aws_secret_key"],
          region_name: request_body_params["aws_region_name"],
          project_id: @project.id
        )
        Location.create_with_id(
          display_name: request_body_params["name"],
          name: "#{@project.ubid}-aws-#{request_body_params["aws_region_name"]}",
          ui_name: request_body_params["name"],
          visible: false,
          provider: "aws",
          aws_location_credential_id: alc.id
        )
        alc
      end

      if api?
        Serializers::AwsRegion.serialize(loc)
      else
        flash["notice"] = "The region is created successfully with path #{@project.path}#{loc.path}."
        r.redirect "#{@project.path}#{loc.path}"
      end
    end

    r.get(web?, "create") do
      authorize("AwsLocationCredential:create", @project.id)

      options = OptionTreeGenerator.new
      options.add_option(name: "name")
      options.add_option(name: "aws_region_name", values: Option::AWS_REGIONS.map { |r| {value: r, display_name: r} })
      options.add_option(name: "aws_access_key")
      options.add_option(name: "aws_secret_key")
      @option_tree, @option_parents = options.serialize

      view "aws-region/create"
    end

    r.is String do |region_ubid|
      @region = @project.aws_location_credentials_dataset.first(id: UBID.to_uuid(region_ubid))

      next(r.delete? ? 204 : 404) unless @region

      r.get do
        authorize("AwsLocationCredential:view", @project.id)

        if api?
          Serializers::AwsRegion.serialize(@region)
        else
          view "aws-region/show"
        end
      end

      r.delete do
        authorize("AwsLocationCredential:delete", @project.id)

        if @region.has_resources
          fail DependencyError.new("'#{@region.name}' region has some resources. Delete all related resources first.")
        end

        @region.location.destroy
        @region.destroy
        204
      end

      r.post do
        authorize("AwsLocationCredential:edit", @project.id)
        @region.location.update(ui_name: r.params["name"], display_name: r.params["name"])

        if api?
          Serializers::AwsRegion.serialize(@region)
        else
          flash["notice"] = "The region name is updated to '#{@region.location.ui_name}'."
          r.redirect "#{@project.path}#{@region.path}"
        end
      end
    end
  end
end
