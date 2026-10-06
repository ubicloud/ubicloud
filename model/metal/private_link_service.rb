# frozen_string_literal: true

# Prog::Vnet::PrivateLinkServiceNexus.assemble refuses non-AWS locations.
class PrivateLinkService < Sequel::Model
  module Metal
    private

    def metal_forget_private_dns_verification
      fail "Private link services are not supported on metal locations"
    end
  end
end
