# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    ie_endpoint_helper = Routes::Common::InferenceEndpointHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.on "private" do
      r.get true do
        ie_endpoint_helper.list
      end

      r.post true do
        # API request for resource creation already has location in the URL.
        # However for web endpoints the location is selected from the UI and
        # cannot be dynamically put to the form's action. due to csrf checks.
        # So we need to set the location here.
        ie_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
        ie_endpoint_helper.post(name: r.params["name"])
      end

      r.on "create" do
        r.get true do
          ie_endpoint_helper.view_create_page
        end
      end
    end

    r.on "public" do
      r.get true do
        ie_endpoint_helper.list_public
      end
    end
  end
end
