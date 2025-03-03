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
      authorize("AwsRegion:create", @project.id)
      required_parameters = ["name", "aws_region_name", "aws_access_key", "aws_secret_key"]
      request_body_params = validate_request_params(required_parameters)

      Validation.validate_name(request_body_params["name"])
      Validation.validate_aws_region_name(request_body_params["aws_region_name"])

      pl = DB.transaction do
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
      end

      if api?
        Serializers::AwsRegion.serialize(pl)
      else
        r.redirect "#{@project.path}/aws-region"
      end
    end

    r.get(web?, "create") do
      authorize("AwsRegion:create", @project.id)
      @available_aws_regions = ["us-east-1", "us-west-1"]
      view "aws-region/create"
    end

    r.is String do |region_ubid|
      @region = @project.aws_location_credentials_dataset.first(id: UBID.to_uuid(region_ubid))

      next(r.delete? ? 204 : 404) unless @region

      r.get do
        authorize("AwsRegion:view", @project.id)

        if api?
          Serializers::AwsRegion.serialize(@region)
        else
          view "aws-region/show"
        end
      end

      r.delete do
        authorize("AwsRegion:delete", @project.id)

        if @region.has_resources
          fail DependencyError.new("'#{@region.name}' region has some resources. Delete all related resources first.")
        end

        @region.location.destroy
        @region.destroy
        if api?
          204
        else
          r.redirect "#{@project.path}/aws-region/index"
        end
      end

      r.post do
        authorize("AwsRegion:edit", @project.id)
        @region.location.update(ui_name: r.params["name"], display_name: r.params["name"])

        if api?
          Serializers::AwsRegion.serialize(@region)
        else
          flash["notice"] = "The region name is updated to '#{@region.location.ui_name}'."
          r.redirect @region.path
        end
      end
    end
  end
end
