# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Gcp
    private

    def gcp_connect_subnet(subnet)
      raise "Connected subnets are not supported for GCP"
    end

    def gcp_disconnect_subnet(subnet)
      raise "Connected subnets are not supported for GCP"
    end

    # GCP reserves the network and default gateway (first two) and the
    # second-to-last and broadcast (last two) addresses of every primary
    # IPv4 subnet range. See:
    # https://cloud.google.com/vpc/docs/subnets#reserved_ip_addresses_in_every_subnet
    def gcp_ipv4_reservation
      [2, 2]
    end
  end
end
