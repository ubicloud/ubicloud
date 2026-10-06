# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-link-service") do |r|
    r.get api? do
      next unless private_link_service_enabled?

      private_link_service_api_list
    end

    r.web do
      r.on String do |provider|
        next unless private_link_service_provider_enabled?(provider)

        r.get true do
          private_link_service_list(provider)
        end

        r.get "create" do
          authorize("PrivateLinkService:create", @project)
          private_link_service_load_options(provider)
          view "networking/private_link_service/#{provider}/create"
        end

        r.post true do
          handle_validation_failure("networking/private_link_service/#{provider}/create") { private_link_service_load_options(provider) }
          public_send(:"private_link_service_#{provider}_post")
        end
      end
    end
  end
end
