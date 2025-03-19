# frozen_string_literal: true

module Ubicloud
  class PrivateSubnet < Model
    set_prefix "ps"

    set_fragment "private-subnet"

    set_columns :id, :name, :state, :location, :net4, :net6, :firewalls, :nics

    set_associations do
      {firewalls: Firewall}
    end

    def connect(subnet)
      subnet = subnet.id if subnet.is_a?(PrivateSubnet)
      merge_into_values(adapter.post(path("/connect"), "connected-subnet-ubid": subnet))
    end

    def disconnect(subnet)
      subnet = subnet.id if subnet.is_a?(PrivateSubnet)
      raise Error, "invalid private subnet id format" if subnet.include?("/")
      merge_into_values(adapter.post(path("/disconnect/#{subnet}")))
    end
  end
end
