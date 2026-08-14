# frozen_string_literal: true

module Ubicloud
  class Vm < Model
    set_prefix "vm"

    set_fragment "vm"

    set_columns :id, :name, :state, :location, :size, :unix_user, :storage_size_gib, :ip6, :ip4_enabled, :ip4, :firewalls, :private_ipv4, :private_ipv6, :subnet, :maintenance_window_start_at, :maintenance_window_days

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

    # Set the maintenance window. start_hour is the start hour (0-23), or nil to
    # unset the window. days is an optional array of 3-letter lowercase day
    # names (e.g. ["mon", "wed"]).
    def set_maintenance_window(start_hour, days: nil)
      params = {}
      if start_hour
        params[:maintenance_window_start_at] = start_hour
      end
      if days
        params[:maintenance_window_days] = days
      end
      merge_into_values(adapter.post(_path("/set-maintenance-window"), params))
    end
  end
end
