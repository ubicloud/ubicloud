# frozen_string_literal: true

# Prog::Vnet::PrivateLinkServiceNexus.assemble refuses non-AWS locations.
class PrivateLinkService < Sequel::Model
  module Gcp
    private

    def gcp_forget_private_dns_verification
    end
  end
end
