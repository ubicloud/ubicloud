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

    # Row-level lock serializes cap-sensitive mutations on this subnet.
    # The VM-joins-subnet path (Prog::Vm::Nexus.assemble) must also lock
    # the subnet row before reading firewall/vm counts, so the two paths
    # can't each pass a stale snapshot check and both commit over the
    # 9-cap.
    def gcp_validate_firewall_attachment(firewall)
      lock!
      DB.ignore_duplicate_queries do
        vms(reload: true).each do |vm|
          vm.validate_firewall_cap(firewall)
        end
      end
    end

    # Membership changes (firewall<->subnet) need both VPC-level rule sync
    # and per-VM tag-binding reconciliation: rules live on the shared
    # firewall policy attached to the VPC, and membership also changes
    # which secure tags each VM must carry. The subnet nexus's wait
    # handler doesn't fan out to VMs on GCP, so we incr the per-VM
    # semaphore here directly.
    def gcp_apply_firewalls
      gcp_vpc.incr_update_firewall_rules
      Semaphore.incr(vms_dataset.select(Sequel[:vm][:id]), :update_firewall_rules)
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
