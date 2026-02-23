# frozen_string_literal: true

class Vm < Sequel::Model
  module Gcp
    private

    def gcp_ip6
      ephemeral_net6&.nth(0)
    end

    def gcp_update_firewall_rules_prog
      Prog::Vnet::Gcp::UpdateFirewallRules
    end
  end
end

# Table: vm
# Columns:
#  id                      | uuid                     | PRIMARY KEY
#  ephemeral_net6          | cidr                     |
#  vm_host_id              | uuid                     |
#  unix_user               | text                     | NOT NULL
#  public_key              | text                     | NOT NULL
#  display_state           | vm_display_state         | NOT NULL DEFAULT 'creating'::vm_display_state
#  name                    | text                     | NOT NULL
#  boot_image              | text                     | NOT NULL
#  local_vetho_ip          | cidr                     |
#  ip4_enabled             | boolean                  | NOT NULL DEFAULT false
#  family                  | text                     | NOT NULL
#  cores                   | integer                  | NOT NULL
#  pool_id                 | uuid                     |
#  created_at              | timestamp with time zone | NOT NULL DEFAULT now()
#  arch                    | arch                     | NOT NULL DEFAULT 'x64'::arch
#  allocated_at            | timestamp with time zone |
#  provisioned_at          | timestamp with time zone |
#  vcpus                   | integer                  | NOT NULL
#  memory_gib              | integer                  | NOT NULL
#  vm_host_slice_id        | uuid                     |
#  project_id              | uuid                     | NOT NULL
#  cpu_percent_limit       | integer                  |
#  cpu_burst_percent_limit | integer                  |
#  location_id             | uuid                     | NOT NULL
# Indexes:
#  vm_pkey                             | PRIMARY KEY btree (id)
#  vm_ephemeral_net6_key               | UNIQUE btree (ephemeral_net6)
#  vm_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
#  vm_pool_id_index                    | btree (pool_id) WHERE pool_id IS NOT NULL
# Foreign key constraints:
#  vm_location_id_fkey      | (location_id) REFERENCES location(id)
#  vm_pool_id_fkey          | (pool_id) REFERENCES vm_pool(id)
#  vm_project_id_fkey       | (project_id) REFERENCES project(id)
#  vm_vm_host_id_fkey       | (vm_host_id) REFERENCES vm_host(id)
#  vm_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
# Referenced By:
#  assigned_vm_address        | assigned_vm_address_dst_vm_id_fkey    | (dst_vm_id) REFERENCES vm(id)
#  dns_servers_vms            | dns_servers_vms_vm_id_fkey            | (vm_id) REFERENCES vm(id)
#  firewalls_vms              | firewalls_vms_vm_id_fkey              | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
#  gpu_partition              | gpu_partition_vm_id_fkey              | (vm_id) REFERENCES vm(id)
#  inference_endpoint_replica | inference_endpoint_replica_vm_id_fkey | (vm_id) REFERENCES vm(id)
#  inference_router_replica   | inference_router_replica_vm_id_fkey   | (vm_id) REFERENCES vm(id)
#  kubernetes_node            | kubernetes_node_vm_id_fkey            | (vm_id) REFERENCES vm(id)
#  load_balancers_vms         | load_balancers_vms_vm_id_fkey         | (vm_id) REFERENCES vm(id)
#  minio_server               | minio_server_vm_id_fkey               | (vm_id) REFERENCES vm(id)
#  nic                        | nic_vm_id_fkey                        | (vm_id) REFERENCES vm(id)
#  pci_device                 | pci_device_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
#  postgres_server            | postgres_server_vm_id_fkey            | (vm_id) REFERENCES vm(id)
#  victoria_metrics_server    | victoria_metrics_server_vm_id_fkey    | (vm_id) REFERENCES vm(id)
#  vm_init_script             | vm_init_script_id_fkey                | (id) REFERENCES vm(id)
#  vm_storage_volume          | vm_storage_volume_vm_id_fkey          | (vm_id) REFERENCES vm(id)
