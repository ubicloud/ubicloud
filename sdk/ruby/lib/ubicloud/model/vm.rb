# frozen_string_literal: true

module Ubicloud
  class Vm < Model
    set_prefix "vm"

    set_fragment "vm"

    set_columns :id, :name, :state, :location, :size, :unix_user, :storage_size_gib, :ip6, :ip4_enabled, :ip4, :firewalls, :private_ipv4, :private_ipv6, :subnet

    set_associations do
      {
        firewalls: Firewall,
        subnet: PrivateSubnet,
      }
    end

    set_create_param_defaults do |params|
      params[:public_key] = params[:public_key]&.gsub(/(?<!\r)\n/, "\r\n")
    end

    # Schedule a restart of the virtual machine. Returns self.
    def restart
      merge_into_values(adapter.post(_path("/restart")))
    end

    # Schedule a start of the virtual machine. Returns self.
    def start
      merge_into_values(adapter.post(_path("/start")))
    end

    # Schedule a stop of the virtual machine. Returns self.
    # Note that stopped virtual machines still accrue billing charges.
    # To avoid billing charges, destroy the virtual machine.
    def stop
      merge_into_values(adapter.post(_path("/stop")))
    end

    # Return the status/output of the most recent serial console log fetch
    # for this virtual machine, as a hash. Returns an empty hash if a fetch
    # has not been requested yet.
    def serial_console
      adapter.get(_path("/serial-console"))
    end

    # Request a fresh fetch of the virtual machine's serial console log.
    # Returns the same shape as +serial_console+. Repeated calls shortly
    # after a successful fetch return the same cached result rather than
    # triggering another fetch.
    def fetch_serial_console
      adapter.post(_path("/serial-console"))
    end
  end
end
