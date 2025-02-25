# frozen_string_literal: true

class Clover
  hash_branch("region") do |r|
    r.get true do
      regions = current_account.projects_dataset.where(visible: true).all.map { |p| p.customer_aws_regions }.flatten

      if api?
        Serializers::Region.serialize(regions)
      else
        @regions = Serializers::Region.serialize(regions)
        view "region/index"
      end
    end

    r.post true do
      required_parameters = ["name", "aws_region_name", "aws_access_key", "aws_secret_key", "project_id"]
      request_body_params = validate_request_params(required_parameters)
      puts "request_body_params: #{request_body_params.inspect}"
      project = Project.from_ubid(request_body_params["project_id"])
      unless project
        if api?
          fail ValidationError.new("Project not found")
        else
          r.redirect "/region"
        end
      end

      puts "project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?"
      puts project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?
      puts "current_account_id: #{current_account_id}"
      puts "project.accounts_dataset: #{project.accounts}"
      puts "project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id): #{project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id)}"
      if project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?
        fail Authorization::Unauthorized
      end

      pl = DB.transaction do
        caa = CustomerAwsRegion.create_with_id(
          access_key: request_body_params["aws_access_key"],
          secret_key: request_body_params["aws_secret_key"],
          project_id: project.id
        )
        Location.create_with_id(
          display_name: request_body_params["name"].downcase.tr(" ", "-"),
          name: "aws-#{request_body_params["aws_region_name"]}",
          ui_name: request_body_params["name"],
          visible: true,
          provider: "aws",
          customer_aws_region_id: caa.id
        )
      end

      if api?
        Serializers::Region.serialize(pl)
      else
        r.redirect "region"
      end
    end

    r.get(web?, "create") do
      @projects = Serializers::Project.serialize(current_account.projects_dataset.where(visible: true).all)

      view "region/create"
    end

    r.on String do |region_ubid|
      @region = CustomerAwsRegion.from_ubid(region_ubid)
      @region = nil unless @region&.visible

      next(r.delete? ? 204 : 404) unless @region

      if @region.project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?
        fail Authorization::Unauthorized
      end

      @region_data = Serializers::Region.serialize(@region)
      @region_permissions = all_permissions(@region.id) if web?

      r.get true do
        authorize("Region:view", @region.id)

        if api?
          Serializers::Region.serialize(@region)
        else
          # @quotas = ["VmVCpu", "PostgresVCpu"].map {
          #   {
          #     resource_type: _1,
          #     current_resource_usage: @project.current_resource_usage(_1),
          #     quota: @project.effective_quota_value(_1)
          #   }
          # }

          view "region/show"
        end
      end

      r.delete true do
        authorize("Region:delete", @region.id)

        if @region.has_resources
          fail DependencyError.new("'#{@region.name}' region has some resources. Delete all related resources first.")
        end

        @region.soft_delete

        204
      end

      if web?
        r.get("dashboard") { view("region/dashboard") }

        r.post true do
          authorize("Region:edit", @region.id)
          @region.update(name: r.params["name"])

          flash["notice"] = "The region name is updated to '#{@region.name}'."

          r.redirect @region.path
        end
      end

      r.hash_branches(:region_prefix)
    end
  end
end
