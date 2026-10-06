# frozen_string_literal: true

class PrivateLinkService < Sequel::Model
  module Aws
    private

    def aws_forget_private_dns_verification
      private_link_service_aws_resource.forget_private_dns_verification
    end
  end
end
