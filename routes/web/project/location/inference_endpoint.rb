# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "inference-endpoint") do |r|
    r.on String do |ie_name|
      ie = @project.inference_endpoints_dataset.where(location: @location).where { {Sequel[:inference_endpoint][:name] => ie_name} }.first

      unless ie
        response.status = 404
        r.halt
      end

      ie_endpoint_helper = Routes::Common::InferenceEndpointHelper.new(app: self, request: r, user: @current_user, location: @location, resource: ie)

      r.get true do
        ie_endpoint_helper.get
      end

      r.delete true do
        ie_endpoint_helper.delete
      end
    end
  end
end
