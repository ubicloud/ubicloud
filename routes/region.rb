# frozen_string_literal: true

class Clover
  hash_branch("region") do |r|
    r.get true do
      dataset = current_account.provider_locations_dataset

      if api?
        result = dataset.paginated_result(
          start_after: r.params["start_after"],
          page_size: r.params["page_size"],
          order_column: r.params["order_column"]
        )

        {
          items: Serializers::AwsRegion.serialize(result[:records]),
          count: result[:count]
        }
      else
        @regions = Serializers::AwsRegion.serialize(dataset.all)
        view "region/index"
      end
    end

    r.post true do
      required_parameters = ["access_key", "secret_key", "location"]
      request_body_params = validate_request_params(required_parameters)
      provider = Provider.find(internal_name: "aws") || Provider.create_with_id(
        display_name: "AWS",
        internal_name: "aws"
      )

      provider_location = ProviderLocation.find(internal_name: request_body_params["location"], account_id: current_account.id) || ProviderLocation.create_with_id(
        display_name: "aws-#{request_body_params["location"]}",
        internal_name: "aws-#{request_body_params["location"]}",
        ui_name: "AWS #{request_body_params["location"]}",
        visible: true,
        account_id: current_account.id,
        provider_id: provider.id
      )

      customer_aws_account = CustomerAwsAccount.create_with_id(
        aws_account_access_key: request_body_params["access_key"],
        aws_account_secret_access_key: request_body_params["secret_key"],
        location: request_body_params["location"],
        provider_location_id: provider_location.id
      )

      if api?
        Serializers::AwsRegion.serialize(customer_aws_account)
      else
        r.redirect customer_aws_account.path
      end
    end

    r.get(web?, "create") { view "region/create" }

    r.on String do |region_ubid|
      @region = CustomerAwsAccount.from_ubid(region_ubid)
      # @region = nil unless @region&.visible

      next(r.delete? ? 204 : 404) unless @region

      # if @region.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?
      #   fail Authorization::Unauthorized
      # end

      r.get true do
        view "region/show"
      end

      r.delete true do
        @region.destroy

        204
      end

      if web?
        r.get("dashboard") { view("region/dashboard") }
      end
    end
  end
end
