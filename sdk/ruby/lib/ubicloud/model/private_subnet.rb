# frozen_string_literal: true

module Ubicloud
  class PrivateSubnet < Model
    set_prefix "ps"

    set_fragment "private-subnet"

    set_columns :id, :name, :state, :location, :net4, :net6, :firewalls, :nics

    set_associations do
      {firewalls: Firewall}
    end

    # Connect the given private subnet to the receiver. Accepts either a PrivateSubnet instance
    # or a private subnet id string. Returns self.
    def connect(subnet)
      merge_into_values(adapter.post(_path("/connect"), "connected-subnet-id": to_id(subnet)))
    end

    # Disconnect the given private subnet from the receiver. Accepts either a PrivateSubnet instance
    # or a private subnet id string. Returns self.
    def disconnect(subnet)
      subnet = to_id(subnet)
      check_no_slash(subnet, "invalid private subnet id format")
      merge_into_values(adapter.post(_path("/disconnect/#{subnet}")))
    end
  end
end
